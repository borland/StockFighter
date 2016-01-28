//
//  level1-first_steps.swift
//  StockFighter
//
//  Created by Orion Edwards on 29/01/16.
//  Copyright © 2016 Orion Edwards. All rights reserved.
//

import Foundation

func first_steps(apiClient:StockFighterApiClient, _ gm:StockFighterGmClient) {

    // use the GM api to RESTART the level (so we can complete it quickly), then quickly just purchase 100 shares at $100
    
    var tradingAccount = ""
    var venueIdentifier = ""
    var stockSymbol = ""
    do {
//        let initial = try gm.startLevel("first_steps")
//        
//        print("restarting level instance \(initial.instanceId)")
//        try gm.restartLevelInstance(initial.instanceId) // reset the timer
        
        let info = try gm.startLevel("first_steps")
        
        tradingAccount = info.account
        venueIdentifier = info.venues[0]
        stockSymbol = info.tickers[0]
        
        print("GM info: trading with account \(tradingAccount) on exchange \(venueIdentifier) for stock \(stockSymbol)")
    } catch let err {
        print("GM error \(err)")
        return
    }
    
    do {
        let venue = apiClient.venue(account:tradingAccount, name:venueIdentifier)
        
        print("placing order")
        let response = try venue.placeOrderForStock(stockSymbol, price: 10000, qty: 100, direction: .Buy)

        print(response)
    } catch let err {
        print("error: \(err)")
    }
}
