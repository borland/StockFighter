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
    
    
    let engine = TradingEngine(apiClient: apiClient, account: tradingAccount, venue: venueIdentifier)

    engine.trackOrdersForStock(stockSymbol) { order in
        let isOutstanding = engine.outstandingOrdersForStock(stockSymbol).filter{ $0.id == order.id }.count > 0
        
        if order.open { return }
        print("completed a \(order.direction): outstanding=\(isOutstanding) position=\(engine.positionForStock(stockSymbol)), profit=\(engine.netProfit)")
    }
    
    let margin = 0 // under/overbid the market by x cents
    let blockSize = 250 // it always sells in blockSize even if it doesn't have that many shares
    
    let position = { engine.positionForStock(stockSymbol) }
    let outstandingBuys = { engine.outstandingOrdersForStock(stockSymbol).filter{ $0.direction == .Buy }.count }
    let outstandingSells = { engine.outstandingOrdersForStock(stockSymbol).filter{ $0.direction == .Sell }.count }
    
    let arrayMin = { (items:[Int]) in items.reduce(Int.max) { min($0, $1) } }
    let arrayMax = { (items:[Int]) in items.reduce(0) { max($0, $1) } }
    
    // this algorithm doesn't seem to work very well although my NAV does seem to creep up slowly over time
    //
    // The code ends up selling for more than it's buying for a lot of the time. I'm not sure if that's just the market
    // moving up and down, or if I need to do more tracking
    //
    // I won the level by dumb luck. I cancelled when I had some stock, and the price
    // went up on it's own
    
    engine.trackQuotesForStock(stockSymbol) { quote in
        
        do {
            // just profile the market
            guard let bid = engine.mapReduceLastQuotes(7, map: { $0.bidBestPrice }, reduce: arrayMin),
                ask = engine.mapReduceLastQuotes(7, map: { $0.askBestPrice }, reduce: arrayMax) else
            {
                return // we don't have enough profiling data to decide to buy or not
            }
            
            let buyPrice = bid + margin
            try engine.cancelOrdersForStock(stockSymbol){ oo in oo.direction == .Buy && oo.price < buyPrice } // I want to sell lower than others
            let sellPrice = ask - margin
            try engine.cancelOrdersForStock(stockSymbol){ oo in oo.direction == .Sell && oo.price > sellPrice } // I want to sell lower than others
            
            let expectedProfit = ask - bid
            if expectedProfit < 50 { return } // no point
            
            // buying stocks
            if outstandingBuys() == 0 && position() < 700 { // don't go too long
                print("placing bid at \(buyPrice)")
                try engine.buyStock(stockSymbol, price: buyPrice, qty: blockSize, timeout: 30)
            }
            
            // selling stocks
            if outstandingSells() == 0 && position() > 0 { // don't sell things I don't have
                print("placing ask at \(sellPrice)")
                try engine.sellStock(stockSymbol, price: sellPrice, qty: blockSize, timeout: 30)
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