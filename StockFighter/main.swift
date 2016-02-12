//
//  main.swift
//  StockFighter
//
//  Created by Orion Edwards on 23/12/15.
//  Copyright © 2015 Orion Edwards. All rights reserved.
//

import Foundation


let keyFile = "/Users/orione/Dev/StockFighter/StockFighter/persistent_key"

let queue = dispatch_queue_create("sfApiClient", nil)
let apiClient = try! StockFighterApiClient(keyFile: keyFile, queue: queue)
let gm = try! StockFighterGmClient(keyFile: keyFile)

// run the code for a given level
//first_steps(apiClient, gm)
//chock_a_block(apiClient, gm)
//sell_side(apiClient, gm)
dueling_bulldozers(apiClient, gm)