//
//  TradingEngine.swift
//  StockFighter
//
//  Created by Orion Edwards on 24/01/16.
//  Copyright © 2016 Orion Edwards. All rights reserved.
//

import Foundation

/* Design Ideas/thoughts:

- The trading engine will abstract over the ApiClient so users won't have to deal with the api directly
- The trading engine will create and own it's own dispatch queue which everything will run on (not worried about perf at this point as our HTTP requests are all still blocking anyway)
- something like this:

for each stock we'll have
- our position (number of shares we own)
- the last quote from the ticker tape (if tracked)
- a list of all outstanding orders we have on that stock, one for bids, one for asks

engine.trackQuotes(STOCK, callback?) - spins up a stockfighter websocket to get notified of updates to STOCK and calls callbacks
engine.trackOrders(STOCK, callback?) - spins up a websocket to get notified of orders and calls callback

engine.bid(STOCK, qty, price, type, timeout) - request to BUY. Submits to StockFighter and tracks internally
engine.ask(STOCK, qty, price, type, timeout) - request to SELL. Submits to StockFighter and tracks internally

If the order is not filled by timeout (NSTimeInterval) the engine will cancel it

engine.orderUpdated(callback) - tells the engine to call this callback when we get activity on a bid or ask we placed
*/

// Future TODO: tracking a stock across multiple venues? Would require a refactor
class TradingEngine {
    struct OutstandingOrder {
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
    
    private var _expenses:Int = 0
    private var _income:Int = 0
    
    private var _position:[String:Int] = [:] // key:Stock symbol, value:How many we have
    private var _lastQuotes:[String:QuoteResponse] = [:] // key:Stock symbol
    private var _outstandingOrders:[Int:OutstandingOrder] = [:]
    
    init(apiClient:StockFighterApiClient, account:String, venue:String) {
        queue = dispatch_queue_create("TradingEngine\(venue)", nil)
        _apiClient = apiClient
        _venue = _apiClient.venue(account: account, name: venue)
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
                    guard let _ = self._outstandingOrders[order.id] else { return } // activity from someone else; not tracking this yet

                    if !order.open {
                        print("completed an order")
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
        
            _tapeWebsockets[symbol] = _venue.tickerTapeForStock(symbol, queue: queue) { [weak self] quote in
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
    
    var netProfit:Int { return lock(self) { _income - _expenses } }

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
    func outstandingOrdersForStock(symbol:String) -> [OutstandingOrder] {
        return lock(self) {
            _outstandingOrders.values.filter{ $0.symbol == symbol }
        }
    }
    
    func outstandingBuyCountForStock(symbol:String) -> Int {
        return lock(self) {
            let f = _outstandingOrders.values.filter{ (oo:OutstandingOrder) in oo.symbol == symbol && oo.direction == .Buy }
            return f.count
        }
    }

    func outstandingSellCountForStock(symbol:String) -> Int {
        return lock(self) {
            let f = _outstandingOrders.values.filter{ $0.symbol == symbol && $0.direction == .Sell }
            return f.count
        }
    }
    
    func buyStock(symbol:String, price: Int, qty: Int, timeout:NSTimeInterval? = nil) throws {
        try placeOrder(.Buy, symbol, price, qty, timeout)
    }
    
    func sellStock(symbol:String, price: Int, qty: Int, timeout:NSTimeInterval? = nil) throws {
        try placeOrder(.Sell, symbol, price, qty, timeout)
    }
    
    func cancelOrder(oo:OutstandingOrder) throws {
        try lock(self){
            if let targetId = _outstandingOrders[oo.id]?.id {
                let response = try _venue.cancelOrderForStock(oo.symbol, id: targetId)

                // the order may have been filled!
                processCompletedOrder(response)
                if response.fills.count > 0 {
                    print("cancellation rejected, order was filled at price \(response.price)")
                }
                else {
                    print("canceled order \(targetId) at price \(oo.price)")
                }
            }
        }
        
    }
    
    /** Shuts down the trading engine, closing all websockets and cancelling any outstanding unfilled orders.
     You must call this method or you'll memory leak the websockets and callbacks */
    func close() {
        var socketsToClose:[WebSocketClient] = []
        
        lock(self) {
            for (id, order) in _outstandingOrders {
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
            _expenses += order.fills.reduce(0){ (m,x) in m + x.qty * x.price }
            
            _position[order.symbol] = position + order.fills.reduce(0){ (m,x) in m + x.qty }
        case .Sell:
            // if we sold some stocks, we gained that money and have less of those stocks
            _income += order.fills.reduce(0){ (m,x) in m + x.qty * x.price }
            
            _position[order.symbol] = position - order.fills.reduce(0){ (m,x) in m + x.qty }
        }
        _outstandingOrders[order.id] = nil // it's no longer an outstanding order
        }
    }
    
    private func placeOrder(direction:OrderDirection, _ symbol:String, _ price: Int, _ qty: Int, _ timeout:NSTimeInterval? = nil) throws {
        let response = try _venue.placeOrderForStock(symbol, price: price, qty: qty, direction: direction)
        lock(self) {
            let order = OutstandingOrder(
                id:response.id,
                symbol: response.symbol,
                price: response.price,
                qty:response.originalQty,
                direction:response.direction)
            
            _outstandingOrders[response.id] = order
            
            if let t = timeout {
                let delayTime = dispatch_time(DISPATCH_TIME_NOW, Int64(t * Double(NSEC_PER_SEC)))
                dispatch_after(delayTime, queue) { [weak self] in
                    guard let this = self else { return }
                    lock(this) {
                        if this._outstandingOrders[order.id] != nil {
                            print("order timed out!")
                            do {
                                try this.cancelOrder(order)
                            } catch {} // timeout failed, can't do much
                        }
                    }
                }
            }
        }
    }
}

/** Helpers and things which don't directly need to be in the engine go here */
extension TradingEngine {
    func cancelOrders(orders:[OutstandingOrder]) throws -> [OutstandingOrder] {
        for order in orders {
            try cancelOrder(order)
        }
        return orders
    }
    
    func cancelOrdersForStock(symbol:String, predicate:(OutstandingOrder) -> Bool) throws -> [OutstandingOrder] {
        return try cancelOrders(outstandingOrdersForStock(symbol).filter(predicate)) // filter returns an array not a lazy sequence so this is ok
    }
}