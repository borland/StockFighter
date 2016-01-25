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

let testExchange = client.venue(account: "EXB123456", name: "TESTEX")
print(testExchange.heartbeat())

do {
    let stocks = try testExchange.stocks()
    print(stocks)
    
    let orders = try testExchange.orderBookForStock("FOOBAR")
    print(orders)
    
    let quote = try testExchange.quoteForStock("FOOBAR")
    print(quote)
    
    let order = try testExchange.placeOrderForStock("FOOBAR", price: 100, qty: 10, direction: .Buy)
    print(order)
    
} catch let error {
    print(error)
}