//===------------------------ SwiftScanCAS.swift --------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

@_implementationOnly import CSwiftScan
import struct Foundation.Data

// Swift Package Manager is building with `-disable-implicit-concurrency-module-import`
// to avoid warnings on old SDKs. Explicity importing concurrency if available
// and only adds async APIs when concurrency is available.
#if canImport(_Concurrency)
import _Concurrency
#endif

public final class CachedCompilation {
  let ptr: swiftscan_cached_compilation_t
  private let lib: SwiftScan

  init(_ ptr: swiftscan_cached_compilation_t, lib: SwiftScan) {
    self.ptr = ptr
    self.lib = lib
  }

  public lazy var count: UInt32 = {
    lib.api.swiftscan_cached_compilation_get_num_outputs(ptr)
  }()

  public var isUncacheable: Bool {
    lib.api.swiftscan_cached_compilation_is_uncacheable(ptr)
  }

  deinit {
    lib.api.swiftscan_cached_compilation_dispose(ptr)
  }
}

extension CachedCompilation: Sequence {
  public typealias Element = CachedOutput
  public struct Iterator: IteratorProtocol {
    public typealias Element = CachedOutput
    let limit: UInt32
    let ptr: swiftscan_cached_compilation_t
    let lib: SwiftScan
    var idx: UInt32 = 0
    public mutating func next() -> CachedOutput? {
      guard idx < self.limit else { return nil }
      let output = self.lib.api.swiftscan_cached_compilation_get_output(self.ptr, idx)
      idx += 1
      // output can never be nil.
      return CachedOutput(output!, lib: self.lib)
    }
  }
  public func makeIterator() -> Iterator {
      return Iterator(limit: self.count, ptr: self.ptr, lib: self.lib)
  }
}

public final class CachedOutput {
  let ptr: swiftscan_cached_output_t
  private let lib: SwiftScan

  init(_ ptr: swiftscan_cached_output_t, lib: SwiftScan) {
    self.ptr = ptr
    self.lib = lib
  }

  public func load() throws -> Bool {
    try lib.handleCASError { err_msg in
      lib.api.swiftscan_cached_output_load(ptr, &err_msg)
    }
  }

  public var isMaterialized: Bool {
    lib.api.swiftscan_cached_output_is_materialized(ptr)
  }

  public func getCASID() throws -> String {
    let id = lib.api.swiftscan_cached_output_get_casid(ptr)
    defer { lib.api.swiftscan_string_dispose(id) }
    return try lib.toSwiftString(id)
  }

  public func getOutputKindName() throws -> String {
    let kind = lib.api.swiftscan_cached_output_get_name(ptr)
    defer { lib.api.swiftscan_string_dispose(kind) }
    return try lib.toSwiftString(kind)
  }

  deinit {
    lib.api.swiftscan_cached_output_dispose(ptr)
  }
}

public final class CacheReplayInstance {
  let ptr: swiftscan_cache_replay_instance_t
  private let lib: SwiftScan

  init(_ ptr: swiftscan_cache_replay_instance_t, lib: SwiftScan) {
    self.ptr = ptr
    self.lib = lib
  }

  deinit {
    lib.api.swiftscan_cache_replay_instance_dispose(ptr)
  }
}

public final class CacheReplayResult {
  let ptr: swiftscan_cache_replay_result_t
  private let lib: SwiftScan

  init(_ ptr: swiftscan_cache_replay_result_t, lib: SwiftScan) {
    self.ptr = ptr
    self.lib = lib
  }

  public func getStdOut() throws -> String {
    let str = lib.api.swiftscan_cache_replay_result_get_stdout(ptr)
    return try lib.toSwiftString(str)
  }

  public func getStdErr() throws -> String {
    let str = lib.api.swiftscan_cache_replay_result_get_stderr(ptr)
    return try lib.toSwiftString(str)
  }

  deinit {
    lib.api.swiftscan_cache_replay_result_dispose(ptr)
  }
}

public final class SwiftScanCAS {
  let cas: swiftscan_cas_t
  private let scanner: SwiftScan
  deinit {
    scanner.api.swiftscan_cas_dispose(cas)
  }

  init(cas: swiftscan_cas_t, scanner: SwiftScan) {
    self.cas = cas
    self.scanner = scanner
  }

  private func convert(compilation: swiftscan_cached_compilation_t?) -> CachedCompilation? {
    return compilation?.convert(scanner)
  }
  private func convert(instance: swiftscan_cache_replay_instance_t?) -> CacheReplayInstance? {
    return instance?.convert(scanner)
  }
  private func convert(result: swiftscan_cache_replay_result_t?) -> CacheReplayResult? {
    return result?.convert(scanner)
  }

  public func store(data: Data) throws -> String {
    let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
    data.copyBytes(to: bytes, count: data.count)
    let casid = try scanner.handleCASError { err_msg in
      scanner.api.swiftscan_cas_store(cas, bytes, UInt32(data.count), &err_msg)
    }
    return try scanner.toSwiftString(casid)
  }

  public func computeCacheKey(commandLine: [String], input: String) throws -> String {
    let casid = try scanner.handleCASError { err_msg in
      withArrayOfCStrings(commandLine) { commandArray in
        scanner.api.swiftscan_cache_compute_key(cas,
                                                Int32(commandLine.count),
                                                commandArray,
                                                input.cString(using: String.Encoding.utf8),
                                                &err_msg)
      }
    }
    return try scanner.toSwiftString(casid)
  }

  public func createReplayInstance(commandLine: [String]) throws -> CacheReplayInstance {
    let instance = try scanner.handleCASError { err_msg in
      withArrayOfCStrings(commandLine) { commandArray in
        scanner.api.swiftscan_cache_replay_instance_create(Int32(commandLine.count),
                                                           commandArray,
                                                           &err_msg)
      }
    }
    // Never return nullptr when no error occurs.
    guard let result = convert(instance: instance) else {
      throw DependencyScanningError.casError("unexpected nil for replay instance")
    }
    return result
  }

  public func queryCacheKey(_ key: String, globally: Bool) throws -> CachedCompilation? {
    let result = try scanner.handleCASError { error in
      scanner.api.swiftscan_cache_query(cas, key.cString(using: .utf8), globally, &error)
    }
    return convert(compilation: result)
  }

  public func replayCompilation(instance: CacheReplayInstance, compilation: CachedCompilation) throws -> CacheReplayResult {
    let result = try scanner.handleCASError { err_msg in
      scanner.api.swiftscan_cache_replay_compilation(instance.ptr, compilation.ptr, &err_msg)
    }
    guard let res = convert(result: result) else {
      throw DependencyScanningError.casError("unexpected nil for cache_replay_result")
    }
    return res
  }
}

extension swiftscan_cached_compilation_t {
  func convert(_ lib: SwiftScan) -> CachedCompilation {
    return CachedCompilation(self, lib: lib)
  }
}

extension swiftscan_cache_replay_instance_t {
  func convert(_ lib: SwiftScan) -> CacheReplayInstance {
    return CacheReplayInstance(self, lib: lib)
  }
}

extension swiftscan_cache_replay_result_t {
  func convert(_ lib: SwiftScan) -> CacheReplayResult {
    return CacheReplayResult(self, lib: lib)
  }
}

#if canImport(_Concurrency)
// Async API Vendor
extension CachedCompilation {
  public func makeGlobal() async throws -> Bool {
    class CallbackContext {
      func retain() -> UnsafeMutableRawPointer {
        return Unmanaged.passRetained(self).toOpaque()
      }

      let continuation: CheckedContinuation<Bool, Swift.Error>
      let comp: CachedCompilation
      init(_ continuation: CheckedContinuation<Bool, Swift.Error>, compilation: CachedCompilation) {
        self.continuation = continuation
        self.comp = compilation
      }
    }

    func callbackFunc(_ context: UnsafeMutableRawPointer?, _ error: swiftscan_string_ref_t) {
      let obj = Unmanaged<CallbackContext>.fromOpaque(context!).takeRetainedValue()
      if error.length != 0 {
        if let err = try? obj.comp.lib.toSwiftString(error) {
          obj.continuation.resume(throwing: DependencyScanningError.casError(err))
        } else {
          obj.continuation.resume(throwing: DependencyScanningError.casError("unknown makeGlobal error"))
        }
      }
      obj.continuation.resume(returning: true)
    }

    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Swift.Error>) in
      let context = CallbackContext(continuation, compilation: self)
      lib.api.swiftscan_cached_compilation_make_global_async(ptr, context.retain(), callbackFunc, nil)
    }
  }
}

extension CachedOutput {
  public func load() async throws -> Bool {
    class CallbackContext {
      func retain() -> UnsafeMutableRawPointer {
        return Unmanaged.passRetained(self).toOpaque()
      }

      let continuation: CheckedContinuation<Bool, Swift.Error>
      let output: CachedOutput
      init(_ continuation: CheckedContinuation<Bool, Swift.Error>, output: CachedOutput) {
        self.continuation = continuation
        self.output = output
      }
    }

    func callbackFunc(_ context: UnsafeMutableRawPointer?, _ success: Bool, _ error: swiftscan_string_ref_t) {
      let obj = Unmanaged<CallbackContext>.fromOpaque(context!).takeRetainedValue()
      if error.length != 0 {
        if let err = try? obj.output.lib.toSwiftString(error) {
          obj.continuation.resume(throwing: DependencyScanningError.casError(err))
        } else {
          obj.continuation.resume(throwing: DependencyScanningError.casError("unknown output loading error"))
        }
      }
      obj.continuation.resume(returning: success)
    }

    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Swift.Error>) in
      let context = CallbackContext(continuation, output: self)
      lib.api.swiftscan_cached_output_load_async(ptr, context.retain(), callbackFunc, nil)
    }
  }
}

extension SwiftScanCAS {
  public func queryCacheKey(_ key: String, globally: Bool) async throws -> CachedCompilation? {
    class CallbackContext {
      func retain() -> UnsafeMutableRawPointer {
        return Unmanaged.passRetained(self).toOpaque()
      }

      let continuation: CheckedContinuation<CachedCompilation?, Swift.Error>
      let cas: SwiftScanCAS
      init(_ continuation: CheckedContinuation<CachedCompilation?, Swift.Error>, cas: SwiftScanCAS) {
        self.continuation = continuation
        self.cas = cas
      }
    }

    func callbackFunc(_ context: UnsafeMutableRawPointer?, _ comp: swiftscan_cached_compilation_t?, _ error: swiftscan_string_ref_t) {
      let obj = Unmanaged<CallbackContext>.fromOpaque(context!).takeRetainedValue()
      if error.length != 0 {
        if let err = try? obj.cas.scanner.toSwiftString(error) {
          obj.continuation.resume(throwing: DependencyScanningError.casError(err))
        } else {
          obj.continuation.resume(throwing: DependencyScanningError.casError("unknown cache querying error"))
        }
      }
      obj.continuation.resume(returning: obj.cas.convert(compilation: comp))
    }

    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CachedCompilation?, Swift.Error>) in
      let context = CallbackContext(continuation, cas: self)
      scanner.api.swiftscan_cache_query_async(cas, key.cString(using: .utf8), globally, context.retain(), callbackFunc, nil)
    }
  }

  public func download(with id: String) async throws -> Bool {
    class CallbackContext {
      func retain() -> UnsafeMutableRawPointer {
        return Unmanaged.passRetained(self).toOpaque()
      }

      let continuation: CheckedContinuation<Bool, Swift.Error>
      let cas: SwiftScanCAS
      init(_ continuation: CheckedContinuation<Bool, Swift.Error>, cas: SwiftScanCAS) {
        self.continuation = continuation
        self.cas = cas
      }
    }

    func callbackFunc(_ context: UnsafeMutableRawPointer?, _ success: Bool, _ error: swiftscan_string_ref_t) {
      let obj = Unmanaged<CallbackContext>.fromOpaque(context!).takeRetainedValue()
      if error.length != 0 {
        if let err = try? obj.cas.scanner.toSwiftString(error) {
          obj.continuation.resume(throwing: DependencyScanningError.casError(err))
        } else {
          obj.continuation.resume(throwing: DependencyScanningError.casError("unknown output loading error"))
        }
      }
      obj.continuation.resume(returning: success)
    }

    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Swift.Error>) in
      let context = CallbackContext(continuation, cas: self)
      scanner.api.swiftscan_cache_download_cas_object_async(cas, id.cString(using: .utf8), context.retain(), callbackFunc, nil)
    }
  }
}
#endif
