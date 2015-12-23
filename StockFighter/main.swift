//
//  main.swift
//  StockFighter
//
//  Created by Orion Edwards on 23/12/15.
//  Copyright © 2015 Orion Edwards. All rights reserved.
//

import Foundation

print("Hello, World!")

let client = try! ApiClient(keyFile: "/Users/orione/Dev/StockFighter/StockFighter/persistent_key")

print("heartbeat");

let venue = client.venue("TVYIEX")
let hr = try! venue.heartbeat()
print("heartbeat: ", hr.ok, hr.venue);

let stocks = try! venue.stocks()
print(stocks.symbols)

let orderBook = try! venue.orderBookForStock("DOD")
print(orderBook)

