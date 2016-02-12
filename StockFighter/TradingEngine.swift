//
//  TradingEngine.swift
//  StockFighter
//
//  Created by Orion Edwards on 24/01/16.
//  Copyright © 2016 Orion Edwards. All rights reserved.
//

import Foundation

// Future: tracking a stock across multiple venues? Would require a refactor
class TradingEngine {
    struct Order {
        let id:Int
        let symbol:String
        let price:Int
        let qty:Int
        let direction:OrderDirection
    }
    
    let historicalQuoteBufferSize = 20
    
    let queue:dispatch_queue_t
    
    private let _apiClient:StockFighterApiClient
    private let _venue:Venue
    
    // must lock to access any members
    private var _executionWebsockets:[String:WebSocketClient] = [:]
    private var _tapeWebsockets:[String:WebSocketClient] = [:]
    private var _quoteHistory:[QuoteResponse] = [] // we keep the last n quotes in memory
    
    private var _position:[String:Int] = [:] // key:Stock symbol, value:How many we have
    private var _lastQuotes:[String:QuoteResponse] = [:] // key:Stock symbol

    private var _currentOrders:[Int:Order] = [:] // order's we've placed
    private var _lastPendingOrderId = 0
    private var _pendingOrders:[Int:Order] = [:] // orders we've sent to the server but haven't received the HTTP response for yet
    private var _cancelingOrders:[Int:Order] = [:] // orders we've asked the server to cancel but haven't received an HTTP response yet
    
    private var _inventory:[Order] = [] // things I've bought
    
    init(apiClient:StockFighterApiClient, account:String, venue:String) {
        _apiClient = apiClient
        _venue = _apiClient.venue(account: account, name: venue)
        
        queue = apiClient.queue
    }
    
    /** Establishes a WebSocket connection to track executions for the given stock, and calls your callback
     whenever new execution info arrives from the server.
     
     Once the engine is tracking orders for a stock, it will automatically remove it from the internal list of
     outstanding orders when it becomes filled or cancelled
     
     - Parameter symbol: The stock symbol
     - Parameter callback: Your callback */
    func trackOrdersForStock(symbol:String, callback:((OrderResponse) -> Void)? = nil) {
        lock(self) {
            if _executionWebsockets[symbol] != nil {
                fatalError("tracking the same symbol twice!") // will have to change if we want to track across venue
            }
            
            _executionWebsockets[symbol] = _venue.executionsForStock(symbol, queue: queue) { order in
                lock(self) {
                    guard let _ = self._currentOrders[order.id] else { return } // activity from someone else; not tracking this yet
                    
                    if !order.open {
//                        print("completed an order")
                        self.processCompletedOrder(order)
                    }
                }
                
                if let cb = callback{ cb(order) }
            }
        }
    }
    
    /** Establishes a WebSocket connection to track quotes for the given stock, and calls your callback
     whenever a new quote info arrives from the server.
     
     Once the engine is tracking quotes for a stock, it will automatically store the last quote in the engine
     
     - Parameter symbol: The stock symbol
     - Parameter callback: Your callback */
    func trackQuotesForStock(symbol:String, callback:(QuoteResponse) -> Void) {
        lock(self) {
            if _tapeWebsockets[symbol] != nil {
                fatalError("tracking the same symbol tickerTape twice!") // will have to change if we want to track across venue
            }
            
            _tapeWebsockets[symbol] = _venue.tickerTapeForStock(symbol) { [weak self] quote in
                guard let this = self else { return }
                lock(this) {
                    this._quoteHistory.append(quote)
                    if this._quoteHistory.count > this.historicalQuoteBufferSize {
                        this._quoteHistory.removeFirst()
                    }
                    callback(quote)
                }
            }
        }
    }
    
    var quoteHistory:[QuoteResponse] { return lock(self) { _quoteHistory } }
    
    var position:[String:Int] { return lock(self) { _position } }
    
    /** If there aren't count previous quotes for which selector doesn't return nil, return nil */
    func mapReduceLastQuotes(count:Int, map:(QuoteResponse) -> Int?, reduce:([Int] -> Int)) -> Int? {
        let qh = lock(self) { _quoteHistory } // swift arrays are by value
        var selected = [Int]()
        for var idx = qh.count - 1; idx > 0; --idx {
            if let x = map(qh[idx]) {
                selected.append(x) // reverses order by average doesn't care
            }
            if selected.count >= count {
                break
            }
        }
        
        if selected.count < count { // we can't generate an average of the last n items because there aren't enough
            return nil
        }
        return reduce(selected)
    }
    
    /** Gets the number of shares we have in this stock, or 0 if we have none. We can have negative shares! */
    func positionForStock(symbol:String) -> Int {
        return lock(self) {
            _position[symbol] ?? 0
        }
    }
    
    /** Gets the outstanding orders you have placed for a given stock.
     - Parameter symbol: The stock symbol
     - Returns: Array of outstanding orders */
    func outstandingOrdersForStock(symbol:String) -> [Order] {
        return lock(self) {
            _currentOrders.values.filter{ $0.symbol == symbol } +
                _pendingOrders.values.filter{ $0.symbol == symbol }
        }
    }
    
    func outstandingBuyCountForStock(symbol:String) -> Int {
        return lock(self) {
            let f = outstandingOrdersForStock(symbol).filter{ $0.direction == .Buy }
            return f.count
        }
    }
    
    func outstandingSellCountForStock(symbol:String) -> Int {
        return lock(self) {
            let f = outstandingOrdersForStock(symbol).filter{ $0.direction == .Sell }
            return f.count
        }
    }
    
    @warn_unused_result
    func buyStock(symbol:String, price: Int, qty: Int, timeout:NSTimeInterval? = nil) -> Observable<Order> {
        return placeOrder(.Buy, symbol, price, qty, timeout)
    }
    
    @warn_unused_result
    func sellStock(symbol:String, price: Int, qty: Int, timeout:NSTimeInterval? = nil) -> Observable<Order> {
        return placeOrder(.Sell, symbol, price, qty, timeout)
    }
    
    @warn_unused_result
    func cancelOrder(oo:Order) -> Observable<Void> {
        return lock(self){
            if let order = _currentOrders[oo.id] {
                _currentOrders[oo.id] = nil
                _cancelingOrders[oo.id] = order
                
                return _venue.cancelOrderForStockAsync(oo.symbol, id: oo.id).map { response in
                    
                    lock(self) {
                        // the order may have been filled!
                        self.processCompletedOrder(response)
                    }
                    if response.fills.count > 0 {
                        print("cancellation rejected, \(oo.direction) was filled at price \(response.price)")
                    }
                    else {
                        print("canceled \(oo.direction) \(oo.id) at price \(oo.price)")
                    }
                }

            }
            return Observable.empty()
        }
    }
    
    /** Shuts down the trading engine, closing all websockets and cancelling any outstanding unfilled orders.
     You must call this method or you'll memory leak the websockets and callbacks */
    func close() {
        var socketsToClose:[WebSocketClient] = []
        
        lock(self) {
            for (id, order) in _currentOrders {
                do {
                    try _venue.cancelOrderForStock(order.symbol, id: id)
                } catch {
                    print("Shutdown: failed to cancel an order for \(order.symbol)") // we're shutting down, other than logging not much to do
                }
            }
            
            socketsToClose.appendContentsOf(_executionWebsockets.values)
            socketsToClose.appendContentsOf(_tapeWebsockets.values)
            _executionWebsockets = [:]
            _tapeWebsockets = [:]
        }
        
        for socketClient in socketsToClose { socketClient.close() }
    }
    
    private func processCompletedOrder(order:OrderResponse) {
        lock(self) {
            let position = _position[order.symbol] ?? 0
            
            switch(order.direction) {
            case .Buy:
                // if we bought some stocks, we spent that money and have more of those stocks
//                _inventory.append(Order(id:order.id, symbol:order.symbol, price:order.price, qty:order.originalQty, direction:.Buy))
                
                _position[order.symbol] = position + order.fills.reduce(0){ (m,x) in m + x.qty }
            case .Sell:
                // if we sold some stocks, we gained that money and have less of those stocks

                // if I bought THESE STOCKS for $2, I want to sell them for $2.50 or whatever the spread is, and no less than that
                
                // remove them from the inventory??
                
                _position[order.symbol] = position - order.fills.reduce(0){ (m,x) in m + x.qty }
            }
            _currentOrders[order.id] = nil // it's no longer an outstanding order
        }
    }
    
    @warn_unused_result
    private func placeOrder(direction:OrderDirection, _ symbol:String, _ price: Int, _ qty: Int, _ timeout:NSTimeInterval? = nil) -> Observable<Order> {
        let pendingId:Int = lock(self) {
            _lastPendingOrderId += 1
            let p = _lastPendingOrderId
            _pendingOrders[_lastPendingOrderId] = Order(id: p, symbol: symbol, price: price, qty: qty, direction: direction)
            return p
        }
        
        return _venue.placeOrderForStockAsync(symbol, price: price, qty: qty, direction: direction).map{ response in
            let order = Order(
                id:response.id,
                symbol: response.symbol,
                price: response.price,
                qty:response.originalQty,
                direction:response.direction)

            if let t = timeout {
                let delayTime = dispatch_time(DISPATCH_TIME_NOW, Int64(t * Double(NSEC_PER_SEC)))
                dispatch_after(delayTime, self.queue) { [weak self] in
                    guard let this = self else { return }
                    lock(this) {
                        if this._currentOrders[order.id] != nil {
//                            print("order timed out!")
                            this.cancelOrder(order).subscribe()
                        }
                    }
                }
            }
            
            return lock(self) {
                self._pendingOrders[pendingId] = nil // it's not pending any more
                self._currentOrders[response.id] = order
                return order
            }
        }
    }
}

/** Helpers and things which don't directly need to be in the engine go here */
extension TradingEngine {
    func cancelOrders(orders:[Order]) -> [Order] {
        for order in orders {
            cancelOrder(order).subscribe()
        }
        return orders
    }
    
    func cancelOrdersForStock(symbol:String, predicate:(Order) -> Bool) -> [Order] {
        let ordersToCancel = _currentOrders.values.filter{ $0.symbol == symbol && predicate($0) } // we can't cancel pending orders
        return cancelOrders(Array(ordersToCancel)) // filter returns an array not a lazy sequence so this is ok
    }
}