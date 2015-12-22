//
//  main.swift
//  StockFighter
//
//  Created by Orion Edwards on 23/12/15.
//  Copyright © 2015 Orion Edwards. All rights reserved.
//

import Foundation

print("Hello, World!")

guard let key = NSFileManager.defaultManager().contentsAtPath("persistent_key") else {
    fatalError("can't read key")
}
let client = ApiClient(apiKey:key)

