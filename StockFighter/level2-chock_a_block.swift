//
//  l2.swift
//  StockFighter
//
//  Created by Orion Edwards on 24/01/16.
//  Copyright © 2016 Orion Edwards. All rights reserved.
//

import Foundation

func chock_a_block() {
    
    let KEYFILE = "/Users/orione/Dev/StockFighter/StockFighter/persistent_key"

    var tradingAccount = ""
    var venueIdentifier = ""
    var stockSymbol = ""
    let DONT_EXCEED_PRICE = 99999 // TODO
    
    // use the GM api to pick up account.etc
    let gm = try! StockFighterGmClient(keyFile: KEYFILE)
    do {
        let info = try gm.startLevel("chock_a_block")
        
        tradingAccount = info.account
        assert(info.venues.count == 1)
        venueIdentifier = info.venues[0]
        assert(info.tickers.count == 1)
        stockSymbol = info.tickers[0]
        
        print("GM info: trading with account \(tradingAccount) on exchange \(venueIdentifier) for stock \(stockSymbol)")
    } catch let err {
        print("GM error \(err)")
        return
    }
    
    let client = try! StockFighterApiClient(keyFile: KEYFILE)

    let venue = client.venue(account:tradingAccount, name:venueIdentifier)

    let hr = venue.heartbeat()
    print("heartbeat: ", hr.ok, hr.venue);

    // basic poor strategy: (basically being a market order)
    // quote, place a limit order at the askBestPrice for the askSize. Hopefully we will buy it
    // if the order comes back still open, cancel it and repeat the quote process again
    // if the order comes back closed, repeat the quote process again
    // stop when we've got all of our 100k shares
    
    var sharesToBuy = 100_000
    
    let engine = TradingEngine(apiClient: client, account: tradingAccount, venue: venueIdentifier)
    engine.trackOrdersForStock(stockSymbol) { order in
        if order.open { return } // only interested in filled orders
        
        let filled = order.fills.reduce(0) { (m, fill) in m + fill.qty }

        sharesToBuy -= filled
        print("\(filled) in \(order.fills.count) fills, \(sharesToBuy) remaining")
    }
    
    engine.trackQuotesForStock(stockSymbol) { quote in
        do {
            guard let askBestPrice = quote.askBestPrice else { return }
            
            let buySize = min(quote.askDepth, 1000)
            let buyPrice = min(askBestPrice, DONT_EXCEED_PRICE)
            
            if engine.outstandingOrdersForStock(stockSymbol).count > 0 { // don't place more than one concurrent order
                return
            }
            
            print("sharesToBuy=\(sharesToBuy): ordering \(buySize) shares at price \(buyPrice)")
            
            try engine.buyStock(stockSymbol, price: buyPrice, qty: buySize)
        } catch let err {
            print("error buying shares \(err)")
        }
    }
    
    // keep the program running so async websocket doesn't terminate
    print("press enter to stop")
    let _  = readLine()
    
    engine.close()

}