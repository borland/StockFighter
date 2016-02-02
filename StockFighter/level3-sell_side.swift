//
//  File.swift
//  StockFighter
//
//  Created by Orion Edwards on 3/02/16.
//  Copyright © 2016 Orion Edwards. All rights reserved.
//

import Foundation

func sell_side(apiClient:StockFighterApiClient, _ gm:StockFighterGmClient) {
    
    var tradingAccount = ""
    var venueIdentifier = ""
    var stockSymbol = ""
    
    // use the GM api to pick up account.etc    
    do {
        let info = try gm.startLevel("sell_side")
        
        tradingAccount = info.account
        venueIdentifier = info.venues[0]
        stockSymbol = info.tickers[0]
        
        print("GM info: trading with account \(tradingAccount) on exchange \(venueIdentifier) for stock \(stockSymbol)")
    } catch let err {
        print("GM error \(err)")
        return
        
    }
    
    let venue = apiClient.venue(account:tradingAccount, name:venueIdentifier)
    try! venue.heartbeat()
    
    // plan: watch the quotes come in
    // our plan is to watch the quotes come in, and track the current market spread (max bid price and min ask price)
    // we then go slightly narrower (5c?) and issue a buy at bidPrice + margin and a sell at askPrice - margin
    // 
    // if a new quote arrives which changes the spread, cancel whichever side is no longer valid and re-post.
    // Note this may lead to a lot of cancelling, fair enough
    
    let engine = TradingEngine(apiClient: apiClient, account: tradingAccount, venue: venueIdentifier)
    engine.trackOrdersForStock(stockSymbol) { order in
        let isOutstanding = engine.outstandingOrdersForStock(stockSymbol).filter{ $0.id == order.id }.count > 0
        
        if !order.open { return }
        print("completed a \(order.direction): outstanding=\(isOutstanding) position=\(engine.positionForStock(stockSymbol)), profit=\(engine.netProfit)")
    }
    
    let margin = 5 // under/overbid the market by x cents
    let blockSize = 250
    var trackedBidBestPrice:Int?
    var trackedAskBestPrice:Int?
    
    var placedOrder = false
    
    engine.trackQuotesForStock(stockSymbol) { quote in
        if placedOrder { return }
        
        do {
            let tap = trackedAskBestPrice ?? Int.max
            if let quotePrice = quote.askBestPrice where quotePrice < tap {
                trackedAskBestPrice = quotePrice
                try engine.cancelOrdersForStock(stockSymbol){ oo in oo.direction == .Sell && oo.price > quotePrice } // I want to sell lower than others
            }
            
            let tbp = trackedBidBestPrice ?? Int.min
            if let quotePrice = quote.bidBestPrice where quotePrice > tbp {
                trackedBidBestPrice = quotePrice
                try engine.cancelOrdersForStock(stockSymbol){ oo in oo.direction == .Buy && oo.price < quotePrice } // I want to buy higher than others
            }
            
            if let orderPrice = trackedBidBestPrice where engine.outstandingBuyCountForStock(stockSymbol) == 0 {
                print("placing bid at \(orderPrice)")
                try engine.buyStock(stockSymbol, price: orderPrice + margin, qty: blockSize)
                placedOrder = true
            }
            if let orderPrice = trackedAskBestPrice where engine.outstandingSellCountForStock(stockSymbol) == 0 {
                print("placing ask at \(orderPrice)")
                try engine.sellStock(stockSymbol, price: orderPrice - margin, qty: blockSize)
                placedOrder = true
            }
        } catch let err {
            print("trading error \(err)")
        }
    }
    
    // keep the program running so async websocket doesn't terminate
    print("press enter to stop")
    let _  = readLine()
    
    engine.close()
    
}