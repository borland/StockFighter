//
//  ApiClient.swift
//  StockFighter
//
//  Created by Orion Edwards on 23/12/15.
//  Copyright © 2015 Orion Edwards. All rights reserved.
//

import Foundation


func parseDate(str:String) throws -> NSDate {
    let formatter = NSDateFormatter()
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
    
    guard let d = formatter.dateFromString(str) else { throw ClientErrors.CantParseDate(str) }
    return d
}

enum ClientErrors : ErrorType {
    case CantReadKeyFile, KeyFileInvalidFormat
    case UnexpectedJsonFor(String)
    case CantParseDate(String)
}

// entry point, handles auth, http, etc
// do I want to use async I/O? Probably, but not yet
class ApiClient {
    private let _httpClient:HttpClient
    
    convenience init(keyFile:String) throws {
        guard let keyData = NSFileManager.defaultManager().contentsAtPath(keyFile) else {
            throw ClientErrors.CantReadKeyFile
        }
        guard let key = NSString(data: keyData, encoding: NSUTF8StringEncoding) as? String else {
            throw ClientErrors.KeyFileInvalidFormat
        }
        self.init(apiKey: key)
    }
    
    init(apiKey:String) {
        _httpClient = HttpClient(baseUrlString:"https://api.stockfighter.io/ob/api/", apiKey:apiKey)
    }
    
    func heartbeat() -> HeartbeatResponse {
        do {
            let d = try _httpClient.get("heartbeat") as! [String:AnyObject]
            return HeartbeatResponse(ok: d["ok"] as! Bool, error: d["error"] as! String)
        } catch let e as NSError {
            return HeartbeatResponse(ok: false, error: e.localizedDescription)
        }
        catch let e {
            return HeartbeatResponse(ok: false, error: "Unexpected error! \(e)")
        }
    }
    
    func venue(name:String) -> Venue {
        return Venue(httpClient: _httpClient, name: name)
    }
}

class Venue {
    struct HeartbeatResponse {
        let ok:Bool
        let venue:String
    }
    
    struct StocksResponse {
        let ok:Bool
        let symbols:[Stock]
    }
    
    struct OrderBookResponse {
        let ok:Bool
        let venue:String
        let symbol:String
        let bids:[OrderBookOrder]
        let asks:[OrderBookOrder]
        let ts:NSDate
    }
    
    private let _httpClient:HttpClient
    let name:String
    init(httpClient:HttpClient, name:String) {
        _httpClient = httpClient
        self.name = name
    }
    
    func heartbeat() throws -> Venue.HeartbeatResponse {
        let d = try _httpClient.get("venues/\(name)/heartbeat") as! [String:AnyObject]
        return Venue.HeartbeatResponse(ok: d["ok"] as! Bool, venue: d["venue"] as! String)
    }
    
    func stocks() throws -> Venue.StocksResponse {
        let d = try _httpClient.get("venues/\(name)/stocks") as! [String:AnyObject]
        guard let symbols = d["symbols"] as? [[String:String]] else { throw ClientErrors.UnexpectedJsonFor("symbols") }
        return Venue.StocksResponse(ok: d["ok"] as! Bool, symbols: symbols.map{
            s in Stock(name: s["name"]!, symbol: s["symbol"]!)
        })
    }
    
    func orderBookForStock(symbol:String) throws -> OrderBookResponse {
        let d = try _httpClient.get("venues/\(name)/stocks/\(symbol)") as! [String:AnyObject]
        let bids = d["bids"] as? [[String:AnyObject]] ?? []
        let asks = d["asks"] as? [[String:AnyObject]] ?? []
        
        let transform = { (x:[String:AnyObject]) in OrderBookOrder(price: x["price"] as! Int, qty: x["qty"] as! Int, isBuy: x["isBuy"] as! Bool) }
        
        return Venue.OrderBookResponse(
            ok: d["ok"] as! Bool,
            venue: d["venue"] as! String,
            symbol: d["symbol"] as! String,
            bids: bids.map(transform),
            asks: asks.map(transform),
            ts: try parseDate(d["ts"] as! String))
    }
}

struct OrderBookOrder {
    let price:Int
    let qty:Int
    let isBuy:Bool
}

struct Stock {
    let name:String
    let symbol:String
}

struct HeartbeatResponse {
    let ok:Bool
    let error:String
}

enum OrderDirection {
    case Buy, Sell
}

enum OrderType {
    case Market, Limit, FillOrKill, ImmediateOrCancel
}

struct Order {
    let account:String
    let venue:String
    let symbol:String
    let price:Int64  // in cents so $25.30 is 2530
    let qty:Int32
    let direction:OrderDirection
    let type:OrderType
}

struct OrderFill {
    let price:Int64
    let qty:Int
    let timeStamp:NSDate
}

struct OrderResponse {
    let ok:Bool
    let open:Bool
    let id:Int64
    let account:String
    let venue:String
    let symbol:String
    let price:Int64  // in cents so $25.30 is 2530
    let originalQty:Int32
    let qty:Int32
    let direction:OrderDirection
    let timeStamp:NSDate
    let fills:[OrderFill]
    let totalFilled:Int
}