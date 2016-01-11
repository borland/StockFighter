//
//  main.swift
//  StockFighter
//
//  Created by Orion Edwards on 23/12/15.
//  Copyright © 2015 Orion Edwards. All rights reserved.
//

import Foundation

let ACCOUNT = "RHI63224193"
let VENUE = "BWYBEX"
let STOCK = "MRH"

let client = try! ApiClient(keyFile: "/Users/orione/Dev/StockFighter/StockFighter/persistent_key", account:ACCOUNT)

let venue = client.venue(VENUE)
do {
    let hr = try venue.heartbeat()
    print("heartbeat: ", hr.ok, hr.venue);

    let stocks = try venue.stocks()
    print(stocks.symbols)

//    let orderBook = try venue.orderBookForStock(STOCK)
//    print(orderBook)
    
    // basic crap strategy: (basically being a market order)
    // quote, place a limit order at the askBestPrice for the askSize. Hopefully we will buy it
    // if the order comes back still open, cancel it and repeat the quote process again
    // if the order comes back closed, repeat the quote process again
    // stop when we've got all of our 100k shares
    var sharesToBuy = 100_000
    while sharesToBuy > 0 {
        let quote = try venue.quoteForStock(STOCK)
        print("ordering \(quote.askSize) shares at price \(quote.askBestPrice)")
        
        let response = try venue.placeOrderForStock(STOCK, price: quote.askBestPrice, qty: quote.askSize, direction: .Buy)
        if response.open { // didn't go filled. We could sit and wait but we have no patience
            try venue.cancelOrderForStock(response.symbol, id: response.id)
            continue
        }
        
        // else the response must have been filled. see how many shares we got (in theory with a limit order we should get the exact amount)
        let filled = response.fills.reduce(0) { (m, fill) in m + fill.qty }
        sharesToBuy -= filled
        
        print("\(filled) by \(response.fills.count) fills, \(sharesToBuy) remaining")
    }
    
    print("all done")
    
} catch let err {
    print("Err:", err)
}

