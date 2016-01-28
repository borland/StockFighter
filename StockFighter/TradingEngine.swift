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
    
    let queue:dispatch_queue_t
    
    private let _apiClient:StockFighterApiClient
    private let _venue:Venue
    
    // must dispatch onto queue to access any members
    private var _executionWebsockets:[String:WebSocketClient] = [:]
    private var _tapeWebsockets:[String:WebSocketClient] = [:]
    
    private var _position:[String:Int] = [:] // key:Stock symbol, value:How many we have
    private var _lastQuotes:[String:QuoteResponse] = [:] // key:Stock symbol
    private var _orders:[Int:OutstandingOrder] = [:]
    
    init(apiClient:StockFighterApiClient, account:String, venue:String) {
        queue = dispatch_queue_create("TradingEngine\(venue)", nil)
        _apiClient = apiClient
        _venue = _apiClient.venue(account: account, name: venue)
    }
    
    /** Shuts down the trading engine, closing all websockets and cancelling any outstanding unfilled orders.
    You must call this method or you'll memory leak the websockets and callbacks */
    func close() {
        var socketsToClose:[WebSocketClient] = []
        
        lock(self) {
            for (id, order) in _orders {
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
    
    /** Establishes a WebSocket connection to track executions for the given stock, and calls your callback
     whenever new execution info arrives from the server.
     
     Once the engine is tracking orders for a stock, it will automatically remove it from the internal list of
     outstanding orders when it becomes filled or cancelled
     
     - Parameter symbol: The stock symbol
     - Parameter callback: Your callback */
    func trackOrdersForStock(symbol:String, callback:(OrderResponse) -> Void) {
        lock(self) {
            if _executionWebsockets[symbol] != nil {
                fatalError("tracking the same symbol twice!") // will have to change if we want to track across venue
            }
            
            _executionWebsockets[symbol] = _venue.executionsForStock(symbol, queue: queue) { order in
                lock(self) {
                    guard let _ = self._orders[order.id] else { return } // activity from someone else; not tracking this yet

                    if !order.open {
                        self._orders[order.id] = nil // it's no longer an outstanding order
                    }
                }
                
                callback(order)
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
        
            _tapeWebsockets[symbol] = _venue.tickerTapeForStock(symbol, queue: queue, callback: callback)
        }
    }
    
    /** Gets the outstanding orders you have placed for a given stock.
     - Parameter symbol: The stock symbol
     - Returns: Array of outstanding orders */
    func outstandingOrdersForStock(symbol:String) -> [OutstandingOrder] {
        return lock(self) {
            _orders.values.filter{ o in o.symbol == symbol }
        }
    }
    
    func buyStock(symbol:String, price: Int, qty: Int, timeout:NSTimeInterval? = nil) throws {
        try placeOrder(.Buy, symbol, price, qty, timeout)
    }
    
    func sellStock(symbol:String, price: Int, qty: Int, timeout:NSTimeInterval? = nil) throws {
        try placeOrder(.Sell, symbol, price, qty, timeout)
    }
    
    func cancelOrder(order:OutstandingOrder) throws {
        try _venue.cancelOrderForStock(order.symbol, id: order.id)
        _orders[order.id] = nil
        print("canceled order \(order.id) at price \(order.price)")
        
    }
    
    private func placeOrder(direction:OrderDirection, _ symbol:String, _ price: Int, _ qty: Int, _ timeout:NSTimeInterval? = nil) throws {
        if timeout != nil { fatalError("timeouts not implemented yet") }
        
        let response = try _venue.placeOrderForStock(symbol, price: price, qty: qty, direction: direction)
        lock(self) {
            _orders[response.id] = OutstandingOrder(
                id:response.id,
                symbol: response.symbol,
                price: response.price,
                qty:response.originalQty,
                direction:response.direction)
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