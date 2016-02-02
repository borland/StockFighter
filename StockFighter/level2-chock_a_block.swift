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
    let targetShares = 100_000 - 14370
    let buyUnder = 1_00 // it looks like I'm getting a string of quotes for $x, but seeing orders fill for less than that in the blotter. Don't buy at the quoted price!
    
    let overBudgetPercent = 5.0 // we're willing to go x% over budget
    let dontExceedPrice = Int( Double(63_13) * (1.0 + overBudgetPercent)) // manually got from watching the blotter; tp is 27.33
    let blockSize = 750 // place an order for at most X
    
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
    
    // on a quote, place a limit order at the askBestPrice minus offset (**) for min(750, askSize). Hopefully we will buy it.
    // wait for the order to fill. If we see a lower quote come in, cancel our existing order.
    // Don't place multiple orders on the same stock as that would lead to overpaying
    //
    // If an order fills, don't place another one until the next trading day to (try) avoid a price impact.
    //
    // ** An interesting observation: It's quite common to see stocks trade for up to around $2 *less* than the
    // prices that are arriving in quotes. If we place bids for a lower amount than the quotes, we end up buying
    // shares for less money
    //
    // This doesn't really seem to work. If I buy shares more rapidly then I start to cause a price impact
    // If I buy shares more slowly then I pick them up for a good price, but I can't buy enough shares
    // before the level times out :-(
    
    var sharesToBuy = targetShares
    
    let engine = TradingEngine(apiClient: apiClient, account: tradingAccount, venue: venueIdentifier)
    engine.trackOrdersForStock(stockSymbol) { order in
        if order.open { return } // only interested in filled orders
        
        let filled = order.fills.reduce(0) { (m, fill) in m + fill.qty }

        sharesToBuy -= filled
        print("\(filled) in \(order.fills.count) fills, \(sharesToBuy) remaining")
    }
    
    let concurrentOrderLimit = 1
    var lastOrderTime:NSDate?
    
    engine.trackQuotesForStock(stockSymbol) { quote in
        do {
            if engine.quoteHistory.count < 3 { return } // don't place orders until we've looked at the market a little bit
            
            guard let askBestPrice = quote.askBestPrice else { return }
//            print("quote at \(askBestPrice)")
            
            if askBestPrice > dontExceedPrice {
                print("ignoring as over dontExceedPrice of \(dontExceedPrice)")
                return
            }
            
            let targetPrice = askBestPrice - buyUnder
            
            let buySize = min(quote.askDepth, blockSize)
            let buyPrice = min(targetPrice, dontExceedPrice)


            let ooCount = engine.outstandingOrdersForStock(stockSymbol).count
            if ooCount >= concurrentOrderLimit { // don't place more than x concurrent orders

                // if we have any outstanding orders greater than the quote, cancel it
                let canceledOrders = try engine.cancelOrdersForStock(stockSymbol) { o in o.price > (buyPrice + buyUnder + 5) } // don't cancel if close enough
                
                if (ooCount - canceledOrders.count) > concurrentOrderLimit {
//                    print("tp \(targetPrice); skipping - at max concurrent orders")
                    return
                }
            }
            
            let x = engine.outstandingOrdersForStock(stockSymbol).filter{ $0.price == targetPrice }
            if x.count > 0 {
//                print("tp \(targetPrice); skipping as I have orders at this price already")
                return
            }
            
            // we want to wait a little bit in between placing orders to avoid impacting the price
            // the stockfighter "day" is about 5 seconds
            if let lot = lastOrderTime where NSDate().timeIntervalSinceDate(lot) < 5 {
                // print("tradingDay is \(status.tradingDay): quote at \(askBestPrice) - tp \(targetPrice); skipping as I already placed an order today")
                return
            }
            
            lastOrderTime = NSDate()
            
            print("quote at \(askBestPrice); ordering \(buySize) shares at price \(buyPrice) - \(sharesToBuy) goal in total")
            
            try engine.buyStock(stockSymbol, price: buyPrice, qty: buySize, timeout: 20)


        } catch let err {
            print("error buying shares \(err)")
        }
    }
    
    // keep the program running so async websocket doesn't terminate
    print("press enter to stop")
    let _  = readLine()
    
    engine.close()

}