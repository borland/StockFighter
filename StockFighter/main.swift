//
//  main.swift
//  StockFighter
//
//  Created by Orion Edwards on 23/12/15.
//  Copyright © 2015 Orion Edwards. All rights reserved.
//

import Foundation

// run the code for a given level
//chock_a_block()

let client = try! StockFighterApiClient(keyFile: "/Users/orione/Dev/StockFighter/StockFighter/persistent_key")

print(client.heartbeat())

let testEx = client.venue(account: "TESTACCOUNT", name: "TESTEX")
print(testEx.heartbeat())

do {
    let stocks = try testEx.stocks()
    print(stocks)
    
    let orders = try testEx.orderBookForStock("FOOBAR")
    print(orders)
    
    let quote = try testEx.quoteForStock("FOOBAR")
    print(quote)
    
} catch let error {
    print(error)
}