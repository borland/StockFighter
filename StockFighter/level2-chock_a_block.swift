//
//  l2.swift
//  StockFighter
//
//  Created by Orion Edwards on 24/01/16.
//  Copyright © 2016 Orion Edwards. All rights reserved.
//

import Foundation

func chock_a_block(apiClient:StockFighterApiClient, _ gm:StockFighterGmClient) {
    
    var tradingAccount = ""
    var venueIdentifier = ""
    var stockSymbol = ""
    let targetShares = 100_000 - 1196
    let dontExceedPrice = 6385 // manually got from watching the blotter
    
    // use the GM api to pick up account.etc

    do {
        let info = try gm.startLevel("chock_a_block")
        
        tradingAccount = info.account
        venueIdentifier = info.venues[0]
        stockSymbol = info.tickers[0]
        
        print("GM info: trading with account \(tradingAccount) on exchange \(venueIdentifier) for stock \(stockSymbol)")
    } catch let err {
        print("GM error \(err)")
        return
    }

    let venue = apiClient.venue(account:tradingAccount, name:venueIdentifier)
    
    do {
        try venue.heartbeat()
    } catch let err {
        fatalError("venue is down! \(err)")
    }
    
    // basic poor strategy: (basically being a market order)
    // quote, place a limit order at the askBestPrice for the askSize. Hopefully we will buy it
    // if the order comes back still open, cancel it and repeat the quote process again
    // if the order comes back closed, repeat the quote process again
    // stop when we've got all of our 100k shares
    
    var sharesToBuy = targetShares
    
    let engine = TradingEngine(apiClient: apiClient, account: tradingAccount, venue: venueIdentifier)
    engine.trackOrdersForStock(stockSymbol) { order in
        if order.open { return } // only interested in filled orders
        
        let filled = order.fills.reduce(0) { (m, fill) in m + fill.qty }

        sharesToBuy -= filled
        print("\(filled) in \(order.fills.count) fills, \(sharesToBuy) remaining")
    }
    
    let concurrentOrderLimit = 5
    
    engine.trackQuotesForStock(stockSymbol) { quote in
        do {
            guard let askBestPrice = quote.askBestPrice else { return }
            
            let buySize = min(quote.askDepth, 1000)
            let buyPrice = min(askBestPrice, dontExceedPrice)
            
            if askBestPrice > dontExceedPrice {
                print("quote at \(askBestPrice); ignoring as over dontExceedPrice of \(dontExceedPrice)")
                return
            }

            let ooCount = engine.outstandingOrdersForStock(stockSymbol).count
            if ooCount >= concurrentOrderLimit { // don't place more than x concurrent orders
                // if we have any outstanding orders greater than the quote, cancel it
                let canceledOrders = try engine.cancelOrdersForStock(stockSymbol) { o in o.price > askBestPrice }
                
                if (ooCount - canceledOrders.count) > concurrentOrderLimit {
                    print("quote at \(askBestPrice); skipping - at max concurrent orders")
                    return
                }
            }
            
            let x = engine.outstandingOrdersForStock(stockSymbol).filter{ $0.price == askBestPrice }
            if x.count > 0 {
                print("quote at \(askBestPrice); skipping as I have orders at this price already")
            }

            print("quote at \(askBestPrice); ordering \(buySize) shares at price \(buyPrice) - \(sharesToBuy) goal in total")
            
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