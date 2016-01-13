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
    case CantParseEnum(String, String)
}

// entry point, handles auth, http, etc
// do I want to use async I/O? Probably, but not yet
class ApiClient {
    private let _httpClient:HttpClient
    let account:String
    
    convenience init(keyFile:String, account:String) throws {
        guard let keyData = NSFileManager.defaultManager().contentsAtPath(keyFile) else {
            throw ClientErrors.CantReadKeyFile
        }
        guard let key = NSString(data: keyData, encoding: NSUTF8StringEncoding) as? String else {
            throw ClientErrors.KeyFileInvalidFormat
        }
        self.init(apiKey: key, account: account)
    }
    
    init(apiKey:String, account:String) {
        _httpClient = HttpClient(baseUrlString:"https://api.stockfighter.io/ob/api/", apiKey:apiKey)
        self.account = account
    }
    
    struct HeartbeatResponse {
        let ok:Bool
        let error:String
    }
    
    func heartbeat() -> ApiClient.HeartbeatResponse {
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
        return Venue(httpClient: _httpClient, account:account, name: name)
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
        let timeStamp:NSDate
    }
    
    struct OrderFill {
        let price:Int
        let qty: Int
        let timeStamp: NSDate
        
        init(dictionary:[String:AnyObject]) throws {
            price = dictionary["price"] as! Int
            qty = dictionary["qty"] as! Int
            timeStamp = try parseDate(dictionary["ts"] as! String)
        }
    }
    
    struct OrderResponse {
        let ok:Bool
        let venue:String
        let symbol:String
        let direction:OrderDirection
        let originalQty:Int
        let outstandingQty:Int // this is the quantity *left outstanding*
        let price:Int // the price on the order -- may not match that of fills!
        let type: OrderType
        let id:Int // guaranteed unique *on this venue*
        let account:String
        let timeStamp:NSDate // ISO-8601 timestamp for when we received order
        let fills:[OrderFill] // may have zero or multiple fills.  Note this order presumably has a total of 80 shares worth
        let totalFilled:Int
        let open:Bool
        
        init(dictionary d:[String:AnyObject]) throws {
            ok = d["ok"] as! Bool
            venue = d["venue"] as! String
            symbol = d["symbol"] as! String
            direction = OrderDirection(rawValue: d["direction"] as! String)!
            originalQty = d["originalQty"] as! Int
            outstandingQty = d["qty"] as! Int
            price = d["price"] as! Int
            type = OrderType(rawValue: d["orderType"] as! String)! // docs are wrong, this comes through as "orderType", not "type"
            id = d["id"] as! Int
            account = d["account"] as! String
            timeStamp = try parseDate(d["ts"] as! String)
            self.fills = try (d["fills"] as? [[String:AnyObject]] ?? []).map{ x in try OrderFill(dictionary: x) }
            totalFilled = d["totalFilled"] as! Int
            open = d["open"] as! Bool
        }
    }
    
    struct QuoteResponse {
        let ok:Bool
        let venue:String
        let symbol:String
        let bidBestPrice:Int? // best price currently bid for the stock
        let askBestPrice:Int? // // best price currently offered for the stock
        let bidSize:Int // aggregate size of all orders at the best bid
        let askSize:Int // aggregate size of all orders at the best ask
        let bidDepth:Int  // aggregate size of *all bids*
        let askDepth:Int // aggregate size of *all asks*
        let lastTradePrice:Int // price of last trade
        let lastTradeSize:Int // quantity of last trade
        let lastTradeTimeStamp:NSDate // timestamp of last trade
        let quoteTimeStamp:NSDate // ts we last updated quote at (server-side)
        
        init(dictionary d:[String:AnyObject]) throws {
            ok = d["ok"] as! Bool
            venue = d["venue"] as! String
            symbol =  d["symbol"] as! String
            bidBestPrice = d["bid"] as? Int // may not be present in the response
            askBestPrice = d["ask"] as? Int // may not be present in the response
            bidSize = d["bidSize"] as! Int
            askSize = d["askSize"] as! Int
            bidDepth = d["bidDepth"] as! Int
            askDepth = d["askDepth"] as! Int
            lastTradePrice = d["last"] as! Int
            lastTradeSize = d["lastSize"] as! Int
            lastTradeTimeStamp = try parseDate(d["lastTrade"] as! String)
            quoteTimeStamp = try parseDate(d["quoteTime"] as! String)
        }
    }
    
    private let _httpClient:HttpClient
    let account:String
    let name:String
    
    init(httpClient:HttpClient, account:String, name:String) {
        _httpClient = httpClient
        self.account = account
        self.name = name
    }
    
    func heartbeat() throws -> Venue.HeartbeatResponse {
        let d = try _httpClient.get("venues/\(name)/heartbeat") as! [String:AnyObject]
        return Venue.HeartbeatResponse(ok: d["ok"] as! Bool, venue: d["venue"] as! String)
    }
    
    func stocks() throws -> StocksResponse {
        let d = try _httpClient.get("venues/\(name)/stocks") as! [String:AnyObject]
        guard let symbols = d["symbols"] as? [[String:String]] else { throw ClientErrors.UnexpectedJsonFor("symbols") }
        return StocksResponse(
            ok: d["ok"] as! Bool,
            symbols: symbols.map{ s in Stock(name: s["name"]!, symbol: s["symbol"]!) })
    }
    
    func orderBookForStock(symbol:String) throws -> OrderBookResponse {
        let d = try _httpClient.get("venues/\(name)/stocks/\(symbol)") as! [String:AnyObject]
        let bids = d["bids"] as? [[String:AnyObject]] ?? []
        let asks = d["asks"] as? [[String:AnyObject]] ?? []
        
        let transform = { (x:[String:AnyObject]) in OrderBookOrder(price: x["price"] as! Int, qty: x["qty"] as! Int, isBuy: x["isBuy"] as! Bool) }
        
        return OrderBookResponse(
            ok: d["ok"] as! Bool,
            venue: d["venue"] as! String,
            symbol: d["symbol"] as! String,
            bids: bids.map(transform),
            asks: asks.map(transform),
            timeStamp: try parseDate(d["ts"] as! String))
    }
    
    func quoteForStock(symbol:String) throws -> QuoteResponse {
        let d = try _httpClient.get("venues/\(name)/stocks/\(symbol)/quote") as! [String:AnyObject]
        return try QuoteResponse(dictionary: d)
    }
    
    func placeOrderForStock(symbol:String, price:Int, qty:Int, direction:OrderDirection, type:OrderType = .Limit) throws -> OrderResponse {
        let request:[String:AnyObject] = [
            "account":account,
            "venue":name,
            "stock":symbol,
            "price":price,
            "qty":qty,
            "direction":direction.rawValue,
            "orderType":type.rawValue
        ]

        let d = try _httpClient.post("venues/\(name)/stocks/\(symbol)/orders", body: request)
        return try OrderResponse(dictionary: d as! [String:AnyObject])
    }
    
    func cancelOrderForStock(symbol:String, id:Int) throws -> OrderResponse {
        let d = try _httpClient.delete("venues/\(name)/stocks/\(symbol)/orders/\(id)")
        return try OrderResponse(dictionary: d as! [String:AnyObject])

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

enum OrderDirection : String {
    case Buy = "buy", Sell = "sell"
}

enum OrderType : String {
    case Market = "market", Limit = "limit", FillOrKill = "fill-or-kill", ImmediateOrCancel = "immediate-or-cancel"
}
