//
//  HttpClient.swift
//  StockFighter
//
//  Created by Orion Edwards on 24/12/15.
//  Copyright © 2015 Orion Edwards. All rights reserved.
//

import Foundation

enum HttpErrors : ErrorType {
    case NoResponse
    case UnexpectedStatusCode(Int)
}

class HttpClient : NSObject, NSURLSessionDelegate, NSURLSessionDataDelegate {
    private let _queue = dispatch_queue_create("httpClientQueue", nil)
    private let _baseUrl:NSURL
    private let _apiKey:String
    
    // NSURLSession is inherently asynchronous; use NSCondition to block the calling thread
    private var _syncData = [Int:(NSCondition, NSData?, NSError?)]()     // acquire _queue to access
    
    lazy private var _session:NSURLSession = {
        let sessionConfig = NSURLSessionConfiguration.defaultSessionConfiguration()
        let nsQueue = NSOperationQueue()
        nsQueue.underlyingQueue = self._queue
        return NSURLSession(configuration: sessionConfig, delegate: self, delegateQueue: nsQueue)
        // we must invalidate the session at some point or we leak
    }()
    
    init(baseUrlString:String, apiKey:String) {
        guard let url = NSURL(string: baseUrlString) else { fatalError("invalid baseUrl \(baseUrlString)") }
        _baseUrl = url
        _apiKey = apiKey
    }
    
    func get(path:String) throws -> AnyObject  {
        guard let url = NSURL(string: path, relativeToURL: _baseUrl) else {
            fatalError("Couldn't build a sensible url from \(path)")
        }
        let task = _session.dataTaskWithURL(url)
        
        let condition = NSCondition()
        condition.lock()
        dispatch_sync(_queue) {
            self._syncData[task.taskIdentifier] = (condition, nil, nil)
        }
        task.resume()
        condition.wait()
        condition.unlock()
        
        var returnedError:NSError?
        var returnedData:NSData?
        dispatch_sync(_queue) {
            guard let (_, data, err) = self._syncData[task.taskIdentifier] else {
                fatalError("Can't get thing for taskId \(task.taskIdentifier)")
            }
            returnedData = data
            returnedError = err
            self._syncData.removeValueForKey(task.taskIdentifier)
        }
        
        if let err = returnedError {
            throw err
        }
        
        guard let response = task.response as? NSHTTPURLResponse else { fatalError("No response from completed task?") }
        if response.statusCode != 200 {
            throw HttpErrors.UnexpectedStatusCode(response.statusCode)
        }
        guard let data = returnedData else {
            throw HttpErrors.NoResponse
        }
        
        return try NSJSONSerialization.JSONObjectWithData(data, options: .AllowFragments)
    }
    
    func URLSession(session: NSURLSession, dataTask: NSURLSessionDataTask, didReceiveData data: NSData) {
        // we'll be on _queue so accessing _conditions is safe
        guard let (condition, oldData, error) = _syncData[dataTask.taskIdentifier] else {
            fatalError("no NSCondition for task with id \(dataTask.taskIdentifier)")
        }
        
        assert(oldData == nil, "Cannot assign data twice for response, I haven't written that code")
        _syncData[dataTask.taskIdentifier] = (condition, data, error) // propagate the error back to the caller
    }
    
    func URLSession(session: NSURLSession, task: NSURLSessionTask, didCompleteWithError error: NSError?) {
        // we'll be on _queue so accessing _conditions is safe
        guard let (condition, data, _) = _syncData[task.taskIdentifier] else {
            fatalError("no NSCondition for task with id \(task.taskIdentifier)")
        }
        
        _syncData[task.taskIdentifier] = (condition, data, error) // propagate the error back to the caller
        
        condition.lock()
        condition.signal()
        condition.unlock()
    }
}