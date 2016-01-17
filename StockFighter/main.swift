//
//  main.swift
//  StockFighter
//
//  Created by Orion Edwards on 23/12/15.
//  Copyright © 2015 Orion Edwards. All rights reserved.
//

import Foundation

let ACCOUNT = "BP70276217"
let VENUE = "CSMCEX"
let STOCK = "FDI"
let DONT_EXCEED_PRICE = 7869

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
        let filled = order.fills.reduce(0) { (m, fill) in m + fill.qty }
        
        if order.open { // update on an unfilled order means we would buy those shares when it fills, but we haven't yet
            print("partial fill \(filled), waiting...")
            return
        }
        
        outstandingOrders[order.id] = nil

        sharesToBuy -= filled
        print("\(filled) in \(order.fills.count) fills, \(sharesToBuy) remaining")
    }
    
    let tapeWs = venue.tickerTapeForStock(STOCK) { quote in
        do {
            guard let askBestPrice = quote.askBestPrice else { return }
            
            let buySize = min(quote.askDepth, 1000)
            let buyPrice = min(askBestPrice, DONT_EXCEED_PRICE)
            
            if outstandingOrders.count > 0 { // don't place more than one concurrent order
                return
            }
            
            print("sharesToBuy=\(sharesToBuy): ordering \(buySize) shares at price \(buyPrice)")
            
            let response = try venue.placeOrderForStock(STOCK, price: buyPrice, qty: buySize, direction: .Buy)
            outstandingOrders[response.id] = OutstandingOrder(
                price: response.price,
                qty:response.originalQty,
                direction:response.direction)
            
        } catch let err {
            print("ouch: \(err)")
        }
    }
    
    // keep the program running so async websocket doesn't terminate
    print("press enter to stop")
    let _  = readLine()
    
    tapeWs.close()
    executionsWs.close()
    
    for (id, order) in outstandingOrders {
        print("canceling unfilled order \(id)")
        try venue.cancelOrderForStock(STOCK, id: id)
    }
    
} catch let err {
    print("Err:", err)
}

