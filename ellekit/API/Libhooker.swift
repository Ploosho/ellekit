import Foundation

#if SWIFT_PACKAGE
import ellekitc
#endif

// Libhooker API Implementation
@_cdecl("LBHookMessage")
public func LBHookMessage(_ cls: AnyClass, _ sel: Selector, _ imp: IMP, _ oldptr: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) {
    messageHook(cls, sel, imp, oldptr)
}

@_cdecl("LHStrError")
public func LHStrError(_ err: LIBHOOKER_ERR) -> UnsafeRawPointer? {

    var error: String = ""

    switch err.rawValue {
    case 0: error = "No errors took place"
    case 1: error = "An Objective-C selector was not found. (This error is from libblackjack)"
    case 2: error = "A function was too short to hook"
    case 3: error = "A problematic instruction was found at the start. We can't preserve the original function due to this instruction getting clobbered."
    case 4: error = "An error took place while handling memory pages"
    case 5: error = "No symbol was specified for hooking"
    default: error = "Unknown error"
    }

    return UnsafeRawPointer((error as NSString).utf8String)
}

@_cdecl("LHPatchMemory")
public func LHPatchMemory(_ hooks: UnsafePointer<LHMemoryPatch>, _ count: Int) -> Int {
    for hook in Array(UnsafeBufferPointer(start: hooks, count: count)) {
        if let dest = hook.destination,
           let code = hook.data?.assumingMemoryBound(to: UInt8.self) {
            rawHook(address: dest, code: code, size: mach_vm_size_t(hook.size))
        } else {
            return 1
        }
    }
    return 0
}

@_cdecl("LHExecMemory")
public func LHExecMemory(_ page: UnsafeMutablePointer<UnsafeMutableRawPointer?>, _ data: UnsafeMutableRawPointer, _ size: size_t) -> Int {
    var addr: mach_vm_address_t = 0
    let krt1 = mach_vm_allocate(mach_task_self_, &addr, UInt64(vm_page_size), VM_FLAGS_ANYWHERE)
    guard krt1 == KERN_SUCCESS else {
        if #available(iOS 14.0, macOS 11.0, *) {
            logger.error("ellekit: couldn't allocate base memory")
        }
        print("[-] couldn't allocate base memory:", mach_error_string(krt1) ?? "")
        return 0
    }
    let krt2 = mach_vm_protect(mach_task_self_, addr, UInt64(vm_page_size), 0, VM_PROT_READ | VM_PROT_WRITE)
    guard krt2 == KERN_SUCCESS else {
        if #available(iOS 14.0, macOS 11.0, *) {
            logger.error("ellekit: couldn't set memory to rw*")
        }
        print("[-] couldn't set memory to rw*:", mach_error_string(krt1) ?? "")
        return 0
    }
    memcpy(UnsafeMutableRawPointer(bitPattern: UInt(addr)), data, size)
    let krt3 = mach_vm_protect(mach_task_self_, addr, UInt64(vm_page_size), 0, VM_PROT_READ | VM_PROT_EXECUTE)
    guard krt3 == KERN_SUCCESS else {
        if #available(iOS 14.0, macOS 11.0, *) {
            logger.error("ellekit: couldn't set memory to r*x")
        }
        print("[-] couldn't set memory to r*x:", mach_error_string(krt1) ?? "")
        return 0
    }
    page.pointee = UnsafeMutableRawPointer(bitPattern: UInt(addr))
    return 1
}

@_cdecl("LHHookFunctions")
public func LHHookFunctions(_ hooks: UnsafePointer<LHFunctionHook>, _ count: Int) -> Int {

    let hooksArray = Array(UnsafeBufferPointer(start: hooks, count: count))

    var origPageAddress: mach_vm_address_t = 0
    let krt1 = mach_vm_allocate(mach_task_self_, &origPageAddress, UInt64(vm_page_size), VM_FLAGS_ANYWHERE)

    guard krt1 == KERN_SUCCESS else { return Int(LIBHOOKER_ERR_VM.rawValue) }

    let krt2 = mach_vm_protect(mach_task_self_, origPageAddress, UInt64(vm_page_size), 0, VM_PROT_READ | VM_PROT_WRITE)

    guard krt2 == KERN_SUCCESS else { return Int(LIBHOOKER_ERR_VM.rawValue) }

    var totalSize = 0
    for targetHook in hooksArray {

        guard let target = targetHook.function?.makeReadable() else { return Int(LIBHOOKER_ERR_NO_SYMBOL.rawValue); }

        let functionSize = findFunctionSize(target)

        let (orig, codesize) = getOriginal(
            target, functionSize, origPageAddress, totalSize,
            usedBigBranch: false
        )

        totalSize = (totalSize + codesize)

        if let orig, targetHook.oldptr != nil {
            let setter = unsafeBitCast(targetHook.oldptr, to: UnsafeMutablePointer<UnsafeMutableRawPointer?>.self)
            setter.pointee = orig.makeCallable()
        }

        let _: Void = hook(targetHook.function, targetHook.replacement)

        #if DEBUG
        if let orig = targetHook.oldptr {
            print("[+] ellekit: Performed one hook in LHHookFunctions from \(String(describing: target)) with orig at \(String(describing: orig))")
        } else {
            print("[+] ellekit: Performed one hook in LHHookFunctions from \(String(describing: target)) with no orig")
        }
        #endif
    }

    let krt3 = mach_vm_protect(mach_task_self_, origPageAddress, UInt64(vm_page_size), 0, VM_PROT_READ | VM_PROT_EXECUTE)
    guard krt3 == KERN_SUCCESS else { return Int(LIBHOOKER_ERR_VM.rawValue) }

    return Int(LIBHOOKER_OK.rawValue)
}
