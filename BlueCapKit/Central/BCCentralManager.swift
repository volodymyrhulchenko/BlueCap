//
//  BCCentralManager.swift
//  BlueCap
//
//  Created by Troy Stribling on 6/4/14.
//  Copyright (c) 2014 Troy Stribling. The MIT License (MIT).
//

import Foundation
import CoreBluetooth

// MARK: - CBCentralManagerInjectable -
public protocol CBCentralManagerInjectable {
    var state : CBCentralManagerState {get}
    func scanForPeripheralsWithServices(uuids: [CBUUID]?, options: [String:AnyObject]?)
    func stopScan()
    func connectPeripheral(peripheral: CBPeripheral, options: [String:AnyObject]?)
    func cancelPeripheralConnection(peripheral: CBPeripheral)
}

extension CBCentralManager : CBCentralManagerInjectable {}

// MARK: - BCCentralManager -
public class BCCentralManager : NSObject, CBCentralManagerDelegate {

    // MARK: Serialize Property IO
    static let ioQueue = Queue("us.gnos.blueCap.central-manager.io")

    // MARK: Properties
    private var _afterPowerOnPromise                            = Promise<Void>()
    private var _afterPowerOffPromise                           = Promise<Void>()
    
    private var _isScanning                                     = false

    internal var _afterPeripheralDiscoveredPromise              = StreamPromise<BCPeripheral>()
    internal var discoveredPeripherals                          = BCSerialIODictionary<NSUUID, BCPeripheral>(BCCentralManager.ioQueue)

    public var cbCentralManager: CBCentralManagerInjectable!
    public let centralQueue: Queue

    private var afterPowerOnPromise: Promise<Void> {
        get {
            return BCCentralManager.ioQueue.sync { return self._afterPowerOnPromise }
        }
        set {
            BCCentralManager.ioQueue.sync { self._afterPowerOnPromise = newValue }
        }
    }

    private var afterPowerOffPromise: Promise<Void> {
        get {
            return BCCentralManager.ioQueue.sync { return self._afterPowerOffPromise }
        }
        set {
            BCCentralManager.ioQueue.sync { self._afterPowerOffPromise = newValue }
        }
    }

    internal var afterPeripheralDiscoveredPromise: StreamPromise<BCPeripheral> {
        get {
            return BCCentralManager.ioQueue.sync { return self._afterPeripheralDiscoveredPromise }
        }
        set {
            BCCentralManager.ioQueue.sync { self._afterPeripheralDiscoveredPromise = newValue }
        }
    }

    public var poweredOn : Bool {
        return self.cbCentralManager.state == CBCentralManagerState.PoweredOn
    }
    
    public var poweredOff : Bool {
        return self.cbCentralManager.state == CBCentralManagerState.PoweredOff
    }

    public var peripherals : [BCPeripheral] {
        return Array(self.discoveredPeripherals.values).sort() {(p1: BCPeripheral, p2: BCPeripheral) -> Bool in
            switch p1.discoveredAt.compare(p2.discoveredAt) {
            case .OrderedSame:
                return true
            case .OrderedDescending:
                return false
            case .OrderedAscending:
                return true
            }
        }
    }
    
    public var state: CBCentralManagerState {
        return self.cbCentralManager.state
    }
    
    public var isScanning : Bool {
        return self._isScanning
    }

    // MARK: Initializers
    public override init() {
        self.centralQueue = Queue("us.gnos.blueCap.central-manager.main")
        super.init()
        self.cbCentralManager = CBCentralManager(delegate: self, queue: self.centralQueue.queue)
    }
    
    public init(queue:dispatch_queue_t, options: [String:AnyObject]?=nil) {
        self.centralQueue = Queue(queue)
        super.init()
        self.cbCentralManager = CBCentralManager(delegate: self, queue: self.centralQueue.queue, options: options)
    }

    public init(centralManager: CBCentralManagerInjectable) {
        self.centralQueue = Queue("us.gnos.blueCap.central-manger.main")
        super.init()
        self.cbCentralManager = centralManager
    }

    // MARK: Power ON/OFF
    public func whenPowerOn() -> Future<Void> {
        self.afterPowerOnPromise = Promise<Void>()
        if self.poweredOn {
            self.afterPowerOnPromise.success()
        }
        return self.afterPowerOnPromise.future
    }

    public func whenPowerOff() -> Future<Void> {
        self.afterPowerOffPromise = Promise<Void>()
        if self.poweredOff {
            self.afterPowerOffPromise.success()
        }
        return self.afterPowerOffPromise.future
    }

    // MARK: Manage Peripherals
    public func connectPeripheral(peripheral: BCPeripheral, options: [String:AnyObject]? = nil) {
        if let cbPeripheral = peripheral.cbPeripheral as? CBPeripheral {
            self.cbCentralManager.connectPeripheral(cbPeripheral, options: options)
        }
    }
    
    public func cancelPeripheralConnection(peripheral: BCPeripheral) {
        if let cbPeripheral = peripheral.cbPeripheral as? CBPeripheral {
            self.cbCentralManager.cancelPeripheralConnection(cbPeripheral)
        }
    }

    public func removeAllPeripherals() {
        self.discoveredPeripherals.removeAll()
    }

    public func disconnectAllPeripherals() {
        for peripheral in self.discoveredPeripherals.values {
            peripheral.disconnect()
        }
    }

    // MARK: Scan
    public func startScanning(capacity:Int? = nil, options: [String:AnyObject]? = nil) -> FutureStream<BCPeripheral> {
        return self.startScanningForServiceUUIDs(nil, capacity: capacity)
    }
    
    public func startScanningForServiceUUIDs(uuids: [CBUUID]?, capacity: Int? = nil, options: [String:AnyObject]? = nil) -> FutureStream<BCPeripheral> {
        if !self._isScanning {
            BCLogger.debug("UUIDs \(uuids)")
            self._isScanning = true
            if let capacity = capacity {
                self.afterPeripheralDiscoveredPromise = StreamPromise<BCPeripheral>(capacity: capacity)
            } else {
                self.afterPeripheralDiscoveredPromise = StreamPromise<BCPeripheral>()
            }
            if self.poweredOn {
                self.cbCentralManager.scanForPeripheralsWithServices(uuids, options: options)
            } else {
                self.afterPeripheralDiscoveredPromise.failure(BCError.centralIsPoweredOff)
            }
        }
        return self.afterPeripheralDiscoveredPromise.future
    }
    
    public func stopScanning() {
        if self._isScanning {
            self._isScanning = false
            self.cbCentralManager.stopScan()
            self.afterPeripheralDiscoveredPromise = StreamPromise<BCPeripheral>()
        }
    }
    
    // MARK: CBCentralManagerDelegate
    public func centralManager(_: CBCentralManager, didConnectPeripheral peripheral: CBPeripheral) {
        self.didConnectPeripheral(peripheral)
    }

    public func centralManager(_: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: NSError?) {
        self.didDisconnectPeripheral(peripheral, error:error)
    }

    public func centralManager(_: CBCentralManager, didDiscoverPeripheral peripheral: CBPeripheral, advertisementData: [String:AnyObject], RSSI: NSNumber) {
        self.didDiscoverPeripheral(peripheral, advertisementData:advertisementData, RSSI:RSSI)
    }

    public func centralManager(_: CBCentralManager, didFailToConnectPeripheral peripheral: CBPeripheral, error: NSError?) {
        self.didFailToConnectPeripheral(peripheral, error:error)
    }

    public func centralManager(_: CBCentralManager!, didRetrieveConnectedPeripherals peripherals: [AnyObject]!) {
        BCLogger.debug()
    }
    
    public func centralManager(_: CBCentralManager!, didRetrievePeripherals peripherals: [AnyObject]!) {
        BCLogger.debug()
    }
    
    public func centralManager(_: CBCentralManager, willRestoreState dict: [String:AnyObject]) {
        BCLogger.debug()
    }
    
    public func centralManagerDidUpdateState(_: CBCentralManager) {
        self.didUpdateState()
    }
    
    public func didConnectPeripheral(peripheral: CBPeripheralInjectable) {
        BCLogger.debug("peripheral name \(peripheral.name)")
        if let bcPeripheral = self.discoveredPeripherals[peripheral.identifier] {
            bcPeripheral.didConnectPeripheral()
        }
    }
    
    public func didDisconnectPeripheral(peripheral: CBPeripheralInjectable, error: NSError?) {
        BCLogger.debug("peripheral name \(peripheral.name)")
        if let bcPeripheral = self.discoveredPeripherals[peripheral.identifier] {
            bcPeripheral.didDisconnectPeripheral()
        }
    }
    
    public func didDiscoverPeripheral(peripheral: CBPeripheralInjectable, advertisementData: [String:AnyObject], RSSI: NSNumber) {
        if self.discoveredPeripherals[peripheral.identifier] == nil {
            let bcPeripheral = BCPeripheral(cbPeripheral: peripheral, centralManager: self, advertisements: advertisementData, rssi: RSSI.integerValue)
            BCLogger.debug("peripheral name \(bcPeripheral.name)")
            self.discoveredPeripherals[peripheral.identifier] = bcPeripheral
            self.afterPeripheralDiscoveredPromise.success(bcPeripheral)
        }
    }
    
    public func didFailToConnectPeripheral(peripheral: CBPeripheralInjectable, error: NSError?) {
        BCLogger.debug()
        if let bcPeripheral = self.discoveredPeripherals[peripheral.identifier] {
            bcPeripheral.didFailToConnectPeripheral(error)
        }
    }
    
    public func didUpdateState() {
        switch(self.cbCentralManager.state) {
        case .Unauthorized:
            BCLogger.debug("Unauthorized")
            break
        case .Unknown:
            BCLogger.debug("Unknown")
            break
        case .Unsupported:
            BCLogger.debug("Unsupported")
            break
        case .Resetting:
            BCLogger.debug("Resetting")
            break
        case .PoweredOff:
            BCLogger.debug("PoweredOff")
            if !self.afterPowerOffPromise.completed {
                self.afterPowerOffPromise.success()
            }
            break
        case .PoweredOn:
            BCLogger.debug("PoweredOn")
            if !self.afterPowerOnPromise.completed {
                self.afterPowerOnPromise.success()
            }
            break
        }
    }
    
}
