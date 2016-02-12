//
//  level4-dueling_bulldozers.swift
//  StockFighter
//
//  Created by Orion Edwards on 13/02/16.
//  Copyright © 2016 Orion Edwards. All rights reserved.
//

import Foundation

func dueling_bulldozers(apiClient:StockFighterApiClient, _ gm:StockFighterGmClient) {
    var tradingAccount = ""
    var venueIdentifier = ""
    var stockSymbol = ""
    
    // use the GM api to pick up account.etc
    do {
        let info = try gm.startLevel("dueling_bulldozers")
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
        print("completed a \(order.direction): outstanding=\(isOutstanding) position=\(engine.positionForStock(stockSymbol))")
    }
    
    let margin = 50 // under/overbid the market by x cents
    let blockSize = 50 // it always sells in blockSize even if it doesn't have that many shares
    
    let arrayMin = { (items:[Int]) in items.reduce(Int.max) { min($0, $1) } }
    let arrayMax = { (items:[Int]) in items.reduce(0) { max($0, $1) } }
    
    // this algorithm reliably makes money gradually and should win level 3 in about 10 minutes if you just leave it sitting there
    // it tries to buy at a bit-higher than the min lowest buy price
    // it tries to sell at a bit-lower than the min highest sell price
    //
    // It has some safeguards:
    //
    // - If the expected profit from this would be less than 50c, don't bother
    //
    // - Buy and sell in small blocks (50 or less) and set a short timeout (6s).
    //   This means our orders don't sit around for too long to get exposed to the market moving
    //
    // - Adjust order quantity to buy/sell smaller amounts to compensate if we are too short/long in the stock
    
    engine.trackQuotesForStock(stockSymbol) { quote in
        
        // profile the market
        guard let bid = engine.mapReduceLastQuotes(7, map: { $0.bidBestPrice }, reduce: arrayMin),
            ask = engine.mapReduceLastQuotes(7, map: { $0.askBestPrice }, reduce: arrayMax) else
        {
            return // we don't have enough profiling data to decide to buy or not
        }
        
        let expectedProfit = ask - bid
        if expectedProfit < 50 { return } // no point
        
        // go inside the spread
        let buyPrice = bid + margin
        engine.cancelOrdersForStock(stockSymbol){ oo in oo.direction == .Buy && oo.price > buyPrice }
        
        let sellPrice = ask - margin
        engine.cancelOrdersForStock(stockSymbol){ oo in oo.direction == .Sell && oo.price < sellPrice }
        
        let outstandingBuys = engine.outstandingOrdersForStock(stockSymbol).filter{ $0.direction == .Buy }.count
        let outstandingSells = engine.outstandingOrdersForStock(stockSymbol).filter{ $0.direction == .Sell }.count
        let position = engine.positionForStock(stockSymbol)
        
        let buffer = 500 // don't go long or short by more than this
        let percentOutOfRange = Float(position) / Float(buffer)
        
        // buying a block and sell a block
        if outstandingBuys == 0 && position < buffer { // only buy if not already buying. Slew the order size so as not to go too long
            let qty = percentOutOfRange > 0 ?
                Int(max(5, (Float(blockSize) * (1-percentOutOfRange)))) : // don't buy negative shares
            blockSize
            
            print("placing bid for \(qty) at \(buyPrice)")
            engine.buyStock(stockSymbol, price: buyPrice, qty: qty, timeout: 6).subscribe()
        }
        
        if outstandingSells == 0 && position > -buffer { // only sell if not already selling. Slew the order size so as not to go too short
            let qty = percentOutOfRange < 0 ?
                Int(max(5, (Float(blockSize) * (1+percentOutOfRange)))) : // don't sell negative shares
            blockSize
            
            print("placing ask for \(qty) at \(sellPrice)")
            engine.sellStock(stockSymbol, price: sellPrice, qty: qty, timeout: 6).subscribe()
        }
    }
    
    // keep the program running so async websocket doesn't terminate
    print("press q to stop")
    while true {
        let line = readLine()
        if line == "q" { break }
    }
    
    engine.close()
}