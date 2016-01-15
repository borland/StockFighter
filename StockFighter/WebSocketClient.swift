//
//  WebSocketClient.swift
//  StockFighter
//
//  Created by Orion Edwards on 15/01/16.
//  Copyright © 2016 Orion Edwards. All rights reserved.
//

import Foundation
import SocketRocket

class WebSocketClient : NSObject, SRWebSocketDelegate {
    private let _queue:dispatch_queue_t
    private let _url:NSURL
    private let _webSocket:SRWebSocket
    private let _callback:(AnyObject) -> ()
    
    init(absoluteUrlString:String, onMessageCallback callback:(AnyObject) -> ()) {
        guard let url = NSURL(string: absoluteUrlString) else { fatalError("invalid absoluteUrlString \(absoluteUrlString)") }
        _url = url
        _queue = dispatch_queue_create("webSocketQueue:\(absoluteUrlString)", nil)
        
        _callback = callback
        _webSocket = SRWebSocket(URL: _url)
        super.init()
        
        _webSocket.setDelegateDispatchQueue(_queue)
        _webSocket.delegate = self
        _webSocket.open()
    }
    
    deinit {
        close()
    }
    
    func close() {
        // technically need a lock here; not worried for this app tho
        if _webSocket.delegate == nil { return } // must be already closed
        _webSocket.delegate = nil
        
        _webSocket.close()
    }
    
    func webSocket(webSocket: SRWebSocket, didReceiveMessage message: AnyObject) {
        guard let msg = message as? String else {
            print("webSocket ignoring unexpected non string message")
            return
        }
        
        do {
            guard let data = msg.dataUsingEncoding(NSUTF8StringEncoding, allowLossyConversion: true) else { return }
            let json = try NSJSONSerialization.JSONObjectWithData(data, options: .AllowFragments)
            _callback(json)
            
        } catch let err {
            print("error on \(dispatch_queue_get_label(_queue)) - \(err)")
        }
    }
}
