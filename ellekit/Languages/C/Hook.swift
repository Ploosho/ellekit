import Foundation

#if SWIFT_PACKAGE
import ellekitc
#endif

public func patchFunction(_ function: UnsafeMutableRawPointer, @InstructionBuilder _ instructions: () -> [UInt8]) {

    let code = instructions()

    let size = mach_vm_size_t(MemoryLayout.size(ofValue: code) * code.count) / 8

    code.withUnsafeBufferPointer { buf in
        let result = rawHook(address: function.makeReadable(), code: buf.baseAddress, size: size)
        #if DEBUG
        print(result)
        #else
        _ = result
        #endif
    }
}

public func hook(_ stockTarget: UnsafeMutableRawPointer, _ stockReplacement: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {

    let target = stockTarget.makeReadable()
    let replacement = stockReplacement.makeReadable()

    let targetSize = findFunctionSize(target) ?? 6

    #if DEBUG
    print("[*] ellekit: Size of target:", targetSize as Any)
    #endif

    let branchOffset = (Int(UInt(bitPattern: replacement)) - Int(UInt(bitPattern: target))) / 4

    hooks[target] = replacement

    var code = [UInt8]()

    // fast big branch option
    if targetSize >= 5 && abs(branchOffset / 1024 / 1024) > 128 {
        #if DEBUG
        print("[*] Big branch")
        #endif

        let target_addr = UInt64(UInt(bitPattern: replacement))

        code = assembleJump(target_addr, pc: 0, link: false, big: true)
     } else if abs(branchOffset / 1024 / 1024) > 128 { // tiny function beyond 4gb hook... using exception handler
        if exceptionHandler == nil {
             exceptionHandler = .init()
        }
        code = [0x20, 0x00, 0x20, 0xD4] // brk #1
    } else { // fastest and simplest branch
        #if DEBUG
        print("[*] ellekit: Small branch")
        #endif
        @InstructionBuilder
        var codeBuilder: [UInt8] {
            b(branchOffset)
        }
        code = codeBuilder
    }

    let size = mach_vm_size_t(MemoryLayout.size(ofValue: code) * code.count) / 8

    let orig = getOriginal(
        target,
        targetSize,
        usedBigBranch: abs(branchOffset / 1024 / 1024) > 128 && targetSize >= 5
    )

    let ret = code.withUnsafeBufferPointer { buf in
        let result = rawHook(address: target, code: buf.baseAddress, size: size)
        #if DEBUG
        assert(result == 0, "[-] ellekit: Hook failure for \(target) to \(replacement)")
        #else
        if result != 0 {
            if #available(iOS 14.0, macOS 11.0, *) {
                logger.error("ellekit: Hook failure for \(String(describing: target)) to \(String(describing: target))")
            }
        }
        #endif
        return result
    }
    
    if ret != 0 {
        return nil
    }

    return orig.0?.makeCallable()
}

public func hook(_ originalTarget: UnsafeMutableRawPointer, _ originalReplacement: UnsafeMutableRawPointer) {

    let target = originalTarget.makeReadable()
    let replacement = originalReplacement.makeReadable()

    let targetSize = findFunctionSize(target) ?? 6
    #if DEBUG
    print("[*] ellekit: Size of target:", targetSize as Any)
    #endif

    let branchOffset = (Int(UInt(bitPattern: replacement)) - Int(UInt(bitPattern: target))) / 4

    var code = [UInt8]()

    if targetSize >= 5 && abs(branchOffset / 1024 / 1024) > 128 {
        #if DEBUG
        print("[*] Big branch")
        #endif

        let target_addr = UInt64(UInt(bitPattern: replacement))

        code = assembleJump(target_addr, pc: 0, link: false, big: true)
    } else if abs(branchOffset / 1024 / 1024) > 128 {
        if exceptionHandler == nil {
            exceptionHandler = .init()
        }
        code = [0x20, 0x00, 0x20, 0xD4] // process crash!
    } else {
        #if DEBUG
        print("[*] ellekit: Small branch")
        #endif
        @InstructionBuilder
        var codeBuilder: [UInt8] {
            b(branchOffset)
        }
        code = codeBuilder
    }

    hooks[target] = replacement

    let size = mach_vm_size_t(MemoryLayout.size(ofValue: code) * code.count) / 8

    code.withUnsafeBufferPointer { buf in
        let result = rawHook(address: target, code: buf.baseAddress, size: size)
        #if DEBUG
        assert(result == 0, "[-] ellekit: Hook failure for \(target) to \(replacement)")
        #else
        if result != 0 {
            if #available(iOS 14.0, macOS 11.0, *) {
                logger.error("ellekit: Hook failure for \(String(describing: target)) to \(String(describing: target))")
            }
        }
        #endif
    }
}

@discardableResult
func rawHook(address: UnsafeMutableRawPointer, code: UnsafePointer<UInt8>?, size: mach_vm_size_t) -> Int {
    let newPermissions = VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY
    let enforceThreadSafety = enforceThreadSafety
    if enforceThreadSafety {
        stopAllThreads()
    }
    let krt1 = mach_vm_protect(mach_task_self_, mach_vm_address_t(UInt(bitPattern: address)), mach_vm_size_t(size), 0, newPermissions)
    guard krt1 == KERN_SUCCESS else {
        return Int(krt1)
    }

    memcpy(address, code, Int(size))

    let originalPerms = VM_PROT_READ | VM_PROT_EXECUTE
    let err2 = mach_vm_protect(mach_task_self_,
                               mach_vm_address_t(UInt(bitPattern: address)),
                               mach_vm_size_t(size),
                               0,
                               originalPerms)

    // flush page cache so we don't hit cached unpatched functions
    sys_icache_invalidate(address, Int(vm_page_size))

    guard err2 == 0 else { return Int(err2) }
    if enforceThreadSafety {
        resumeAllThreads()
    }

    return 0
}
