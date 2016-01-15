//
//  main.swift
//  StockFighter
//
//  Created by Orion Edwards on 23/12/15.
//  Copyright © 2015 Orion Edwards. All rights reserved.
//

import Foundation

let ACCOUNT = "SLB4236322"
let VENUE = "UZNEX"
let STOCK = "UAXI"

let queue = dispatch_queue_create("trading_engine", nil)
let client = try! ApiClient(keyFile: "/Users/orione/Dev/StockFighter/StockFighter/persistent_key", account:ACCOUNT, queue: queue)

struct OutstandingOrder {
    let price:Int
    let qty:Int
    let direction:OrderDirection
}

let venue = client.venue(VENUE)
do {
    let hr = try venue.heartbeat()
    print("heartbeat: ", hr.ok, hr.venue);

    let stocks = try venue.stocks()
    print(stocks.symbols)

    // basic crap strategy: (basically being a market order)
    // quote, place a limit order at the askBestPrice for the askSize. Hopefully we will buy it
    // if the order comes back still open, cancel it and repeat the quote process again
    // if the order comes back closed, repeat the quote process again
    // stop when we've got all of our 100k shares

    var sharesToBuy = 100_000
    
    // only tracks our outstanding orders for the one stock. Assume in harder levels we'll have to trade multiple stocks concurrently
    var outstandingOrders = [Int:OutstandingOrder]()
    
    let executionsWs = venue.executionsForStock(STOCK) { order in
        guard let oo = outstandingOrders[order.id] else { return } // activity from someone else; not tracking this yet
        outstandingOrders[order.id] = nil
        
        // else the response must have been filled. see how many shares we got (in theory with a limit order we should get the exact amount)
        let filled = order.fills.reduce(0) { (m, fill) in m + fill.qty }
        sharesToBuy -= filled
        print("\(filled) in \(order.fills.count) fills, \(sharesToBuy) remaining")
    }
    
    let tapeWs = venue.tickerTapeForStock(STOCK) { quote in
        do {
            guard let askBestPrice = quote.askBestPrice else { return }
            
            if outstandingOrders.count > 0 { // don't place more than one concurrent order
                return
            }
            
            print("sharesToBuy=\(sharesToBuy): ordering \(quote.askSize) shares at price \(askBestPrice)")
            
            let response = try venue.placeOrderForStock(STOCK, price: askBestPrice, qty: quote.askSize, direction: .Buy)
            outstandingOrders[response.id] = OutstandingOrder(
                price: response.price,
                qty:response.originalQty,
                direction:response.direction)
            
        } catch let err {
            print("ouch: \(err)")
        }
    }
    
    // keep the program running so async websocket doesn't terminate
    print("press enter to quit")
    let _  = readLine()
    
    tapeWs.close()
    executionsWs.close()
    
} catch let err {
    print("Err:", err)
}

