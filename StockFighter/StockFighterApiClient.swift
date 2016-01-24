//
//  StockFighterApiClient.swift
//
//  Created by Orion Edwards on 23/12/15.
//  Copyright © 2015 Orion Edwards. Licensed under the MIT License
//  https://opensource.org/licenses/MIT
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

/** This class handles interaction with the official StockFighter API as documented at https://starfighter.readme.io */
class StockFighterApiClient {
    private let _httpClient:HttpClient

    /** Inits the client with a file containing your API key.
     This is good because you can put your API key in a separate file, reference it here, but EXCLUDE that file from source control
     as you don't want to be publishing your API key on GitHub (even though StockFighter is just a game)
     
     - Parameter keyFile: Path to a text file which contains your API key */
    convenience init(keyFile:String) throws {
        guard let keyData = NSFileManager.defaultManager().contentsAtPath(keyFile) else {
            throw ClientErrors.CantReadKeyFile
        }
        guard let key = NSString(data: keyData, encoding: NSUTF8StringEncoding) as? String else {
            throw ClientErrors.KeyFileInvalidFormat
        }
        self.init(apiKey: key)
    }
    
    /** Inits the client with your API key. You should probably call `init(keyFile)` instead of this
    - Parameter apiKey: Your API key */
    init(apiKey:String) {
        _httpClient = HttpClient(baseUrlString:"https://api.stockfighter.io/ob/api/", httpHeaders: ["X-Starfighter-Authorization": apiKey])
    }
    
    func heartbeat() -> ApiHeartbeatResponse {
        do {
            let d = try _httpClient.get("heartbeat") as! [String:AnyObject]
            return ApiHeartbeatResponse(ok: d["ok"] as! Bool, error: d["error"] as! String)
        } catch let e as NSError {
            return ApiHeartbeatResponse(ok: false, error: e.localizedDescription)
        }
        catch let e {
            return ApiHeartbeatResponse(ok: false, error: "Unexpected error! \(e)")
        }
    }
    
    func venue(account account:String, name:String) -> Venue {
        return Venue(httpClient: _httpClient, account:account, name: name)
    }
}

class Venue {
    
    private let _httpClient:HttpClient
    let account:String
    let name:String
    
    init(httpClient:HttpClient, account:String, name:String) {
        _httpClient = httpClient
        self.account = account
        self.name = name
    }
    
    func heartbeat() throws -> VenueHeartbeatResponse {
        let d = try _httpClient.get("venues/\(name)/heartbeat") as! [String:AnyObject]
        return VenueHeartbeatResponse(dictionary: d)
    }
    
    func stocks() throws -> StocksResponse {
        let d = try _httpClient.get("venues/\(name)/stocks") as! [String:AnyObject]
        return try StocksResponse(dictionary: d)
    }
    
    func orderBookForStock(symbol:String) throws -> OrderBookResponse {
        let d = try _httpClient.get("venues/\(name)/stocks/\(symbol)") as! [String:AnyObject]
        return try OrderBookResponse(dictionary: d)
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
    
    /** Submits a request to cancel an outstanding order you've placed for a stock
    
    - Parameter symbol: The stock symbol
    - Parameter id: The order id (returned as part of the OrderResponse when you called placeOrderForStock
    - Returns: an OrderResponse
    - Throws: ClientErrors.CantParseDate */
    func cancelOrderForStock(symbol:String, id:Int) throws -> OrderResponse {
        let d = try _httpClient.delete("venues/\(name)/stocks/\(symbol)/orders/\(id)")
        return try OrderResponse(dictionary: d as! [String:AnyObject])
    }
    
    // returns a websocketClient. It's up to the caller to close the client when done
    func tickerTape(queue queue:dispatch_queue_t, callback:(QuoteResponse) -> Void) -> WebSocketClient {
        let url = NSURL(string: "wss://api.stockfighter.io/ob/api/ws/\(account)/venues/\(name)/tickertape")!
        return WebSocketClient(url: url, queue: queue){ obj in
            self.processTickerTapeResponse(obj, callback: callback)
        }
    }
    
    func tickerTapeForStock(symbol:String, queue:dispatch_queue_t, callback:(QuoteResponse) -> Void) -> WebSocketClient {
        let url = NSURL(string: "wss://api.stockfighter.io/ob/api/ws/\(account)/venues/\(name)/tickertape/stocks/\(symbol)")!
        return WebSocketClient(url: url, queue: queue){ obj in
            self.processTickerTapeResponse(obj, callback: callback)
        }
    }
    
    private func processTickerTapeResponse(obj:AnyObject, callback:(QuoteResponse) -> Void) {
        guard let d = obj as? [String:AnyObject] else { return }
        guard let ok = d["ok"] as? Bool where ok ==  true else {
            print("websocket callback missing ok:true")
            return
        }
        guard let qd = d["quote"] as? [String:AnyObject] else {
            print("no quote?")
            return
        }
        do {
            let response = try QuoteResponse(dictionary: qd)
            callback(response)
        } catch let err {
            print("error on websocket queue: \(err)")
        }
    }
    
    func executions(queue queue:dispatch_queue_t, callback:(OrderResponse) -> Void) -> WebSocketClient {
        let url = NSURL(string: "wss://api.stockfighter.io/ob/api/ws/\(account)/venues/\(name)/executions")!
        return WebSocketClient(url: url, queue: queue){ obj in
            self.processExecutionsResponse(obj, callback: callback)
        }
    }
    
    func executionsForStock(symbol:String, queue:dispatch_queue_t, callback:(OrderResponse) -> Void) -> WebSocketClient {
        let url = NSURL(string: "wss://api.stockfighter.io/ob/api/ws/\(account)/venues/\(name)/executions/stocks/\(symbol)")!
        return WebSocketClient(url: url, queue: queue){ obj in
            self.processExecutionsResponse(obj, callback: callback)
        }
    }
    
    private func processExecutionsResponse(obj:AnyObject, callback:(OrderResponse) -> Void) {
        guard let d = obj as? [String:AnyObject] else { return }
        guard let ok = d["ok"] as? Bool where ok ==  true else {
            print("websocket callback missing ok:true")
            return
        }
        guard let od = d["order"] as? [String:AnyObject] else {
            print("no order in executionsResponse")
            return
        }
        do {
            let response = try OrderResponse(dictionary: od)
            callback(response)
        } catch let err {
            print("error on websocket queue: \(err)")
        }
    }
}

// - Mark: Enums

enum OrderDirection : String {
    case Buy = "buy", Sell = "sell"
}

enum OrderType : String {
    case Market = "market", Limit = "limit", FillOrKill = "fill-or-kill", ImmediateOrCancel = "immediate-or-cancel"
}

// - Mark: Data Structures

struct ApiHeartbeatResponse {
    let ok:Bool
    let error:String
}

struct VenueHeartbeatResponse {
    let ok:Bool
    let venue:String
    
    init(dictionary d:[String:AnyObject]) {
        ok = d["ok"] as! Bool
        venue = d["venue"] as! String
    }
}

struct Stock {
    let name:String
    let symbol:String
}

struct StocksResponse {
    let ok:Bool
    let symbols:[Stock]
    
    init(dictionary d:[String:AnyObject]) throws {
        guard let symbolsArr = d["symbols"] as? [[String:String]] else { throw ClientErrors.UnexpectedJsonFor("symbols") }
        
        ok = d["ok"] as! Bool
        symbols = symbolsArr.map{ s in Stock(name: s["name"]!, symbol: s["symbol"]!) }
    }
}

struct OrderBookOrder {
    let price:Int
    let qty:Int
    let isBuy:Bool
    
    init(dictionary d:[String:AnyObject]) {
        price = d["price"] as! Int
        qty = d ["qty"] as! Int
        isBuy = d["isBuy"] as! Bool
    }
}

struct OrderBookResponse {
    let ok:Bool
    let venue:String
    let symbol:String
    let bids:[OrderBookOrder]
    let asks:[OrderBookOrder]
    let timeStamp:NSDate
    
    init(dictionary d:[String:AnyObject]) throws {
        let bidsArr = d["bids"] as? [[String:AnyObject]] ?? []
        let asksArr = d["asks"] as? [[String:AnyObject]] ?? []
        
        let transform = { (x:[String:AnyObject]) in OrderBookOrder(dictionary: x) }
        
        ok = d["ok"] as! Bool
        venue = d["venue"] as! String
        symbol = d["symbol"] as! String
        bids = bidsArr.map(transform)
        asks = asksArr.map(transform)
        timeStamp = try parseDate(d["ts"] as! String)
    }
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
    let fills:[OrderFill] // may have zero or multiple fills.
    let totalFilled:Int
    let open:Bool
    
    init(dictionary d:[String:AnyObject]) throws {
        ok = d["ok"] as? Bool ?? true // if we come in via the websocket ok isn't present (it's in the parent)
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
        ok = d["ok"] as? Bool ?? true // if we come in via a websocket then OK is missing but it exists in the outer response
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