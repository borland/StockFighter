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
        let symbol:String
        let price:Int
        let qty:Int
        let direction:OrderDirection
    }
    
    let queue:dispatch_queue_t
    
    private let _apiClient:ApiClient
    private let _venue:Venue
    
    // must dispatch onto queue to access any members
    private var _executionWebsockets:[String:WebSocketClient] = [:]
    private var _tapeWebsockets:[String:WebSocketClient] = [:]
    
    private var _position:[String:Int] = [:] // key:Stock symbol, value:How many we have
    private var _lastQuotes:[String:Venue.QuoteResponse] = [:] // key:Stock symbol
    private var _orders:[Int:OutstandingOrder] = [:]
    
    init(apiClient:ApiClient, account:String, venue:String) {
        queue = dispatch_queue_create("TradingEngine\(venue)", nil)
        self._apiClient = apiClient
        self._venue = _apiClient.venue(account: account, name: venue)
    }
    
    /*! Shuts down the trading engine, closing all websockets and cancelling any outstanding unfilled orders.
    You must call this method or you'll memory leak the websockets and callbacks */
    func close() {
        dispatch_sync(queue) {
            for (id, order) in self._orders {
                do {
                    try self._venue.cancelOrderForStock(order.symbol, id: id)
                } catch {
                    print("Shutdown: failed to cancel an order for \(order.symbol)") // we're shutting down, other than logging not much to do
                }
            }
            
            for socketClient in self._executionWebsockets.values { socketClient.close() }
            self._executionWebsockets = [:]

            for socketClient in self._tapeWebsockets.values { socketClient.close() }
            self._tapeWebsockets = [:]
        }
    }
    
    func trackOrdersForStock(symbol:String, callback:(Venue.OrderResponse) -> Void) {
        dispatch_sync(queue) {
            if self._executionWebsockets[symbol] != nil {
                fatalError("tracking the same symbol twice!") // will have to change if we want to track across venue
            }
            
            self._executionWebsockets[symbol] = self._venue.executionsForStock(symbol, queue: self.queue) { order in
                guard let _ = self._orders[order.id] else { return } // activity from someone else; not tracking this yet

                if !order.open {
                    self._orders[order.id] = nil // it's no longer an outstanding order
                }
                
                callback(order)
            }
        }
    }
    
    func trackQuotesForStock(symbol:String, callback:(Venue.QuoteResponse) -> Void) {
        dispatch_sync(queue) {
            if self._tapeWebsockets[symbol] != nil {
                fatalError("tracking the same symbol tickerTape twice!") // will have to change if we want to track across venue
            }
        
            self._tapeWebsockets[symbol] = self._venue.tickerTapeForStock(symbol, queue: self.queue, callback: callback)
        }
    }
    
    func outstandingOrdersForStock(symbol:String) -> [OutstandingOrder] {
        var result = [OutstandingOrder]()
        dispatch_sync(queue) {
            result = self._orders.values.filter{ o in o.symbol == symbol }
        }
        return result
    }
    
    func buyStock(symbol:String, price: Int, qty: Int, timeout:NSTimeInterval? = nil) throws {
        try placeOrder(.Buy, symbol, price, qty, timeout)
    }
    
    func sellStock(symbol:String, price: Int, qty: Int, timeout:NSTimeInterval? = nil) throws {
        try placeOrder(.Sell, symbol, price, qty, timeout)
    }
    
    private func placeOrder(direction:OrderDirection, _ symbol:String, _ price: Int, _ qty: Int, _ timeout:NSTimeInterval? = nil) throws {
        if timeout != nil { fatalError("timeouts not implemented yet") }
        
        let response = try _venue.placeOrderForStock(symbol, price: price, qty: qty, direction: direction)
        dispatch_sync(queue) {
            self._orders[response.id] = OutstandingOrder(
                symbol: response.symbol,
                price: response.price,
                qty:response.originalQty,
                direction:response.direction)
        }
    }
}