import Foundation

#if SWIFT_PACKAGE
import ellekitc
#endif

// PAC: strip before calling this function and sign the result afterwards
func getOriginal(_ target: UnsafeMutableRawPointer, _ size: Int? = nil, _ addr: mach_vm_address_t? = nil, _ totalSize: Int? = nil, usedBigBranch: Bool = false) -> (UnsafeMutableRawPointer?, Int) {

    var unpatched = target.withMemoryRebound(to: UInt8.self, capacity: usedBigBranch ? 20 : 4, { ptr in
        Array(UnsafeMutableBufferPointer(start: ptr, count: usedBigBranch ? 20 : 4))
    })

    let target_addr = UInt64(UInt(bitPattern: target))

    if size == 1 {

        #if DEBUG
        print("[*] ellekit: Small function")
        #endif

        let codesize = MemoryLayout<[UInt8]>.size

        let ptr: UnsafeMutableRawPointer?
        if let addr, let totalSize {
            ptr = UnsafeMutableRawPointer(bitPattern: UInt(addr))?.advanced(by: totalSize)
        } else {
            var addr: mach_vm_address_t = 0
            mach_vm_allocate(mach_task_self_, &addr, UInt64(vm_page_size), VM_FLAGS_ANYWHERE)
            mach_vm_protect(mach_task_self_, addr, UInt64(vm_page_size), 0, VM_PROT_READ | VM_PROT_WRITE)
            ptr = UnsafeMutableRawPointer(bitPattern: UInt(addr))
        }
        guard let ptr else { return (nil, 0) }

        let addr: mach_vm_address_t = addr ?? 0

        var code: [UInt8] = []
        let isn = UInt64(combine(unpatched))
        if checkBranch(unpatched) {
            #if DEBUG
            print("[*] ellekit: Redirecting branch")
            #endif
            code = redirectBranch(target, isn, ptr)
        } else {
            unpatched = Array([unpatched].rebind(formerPC: UInt64(UInt(bitPattern: target)), newPC: UInt64(UInt(bitPattern: ptr))).joined())
            @InstructionBuilder
            var codeBuilt: [UInt8] {
                bytes(unpatched) // First instruction of the function that got hooked
            }
            code = codeBuilt
        }

        if let totalSize, let ptr = UnsafeMutableRawPointer(bitPattern: UInt(addr))?.advanced(by: totalSize) {
            memcpy(ptr, code, codesize * code.count)
            #if DEBUG
            print("[+] ellekit: Orig written to:", ptr, "for function", totalSize)
            #endif
        } else {
            memcpy(ptr, code, codesize * code.count)
            let krt = mach_vm_protect(mach_task_self_, mach_vm_address_t(UInt(bitPattern: ptr)), UInt64(vm_page_size), 0, VM_PROT_READ | VM_PROT_EXECUTE)
            guard krt == KERN_SUCCESS else {
                if #available(iOS 14.0, macOS 11.0, *) {
                    logger.error("ellekit: couldn't vm_protect small function orig page")
                }
                print("[-] couldn't vm_protect small function orig page:", mach_error_string(krt) ?? "")
                return (nil, 0)
            }
            #if DEBUG
            print("[+] ellekit: Orig written to:", ptr)
            #endif
        }

        return (ptr, codesize * code.count)
    }

    let ptr: UnsafeMutableRawPointer?

    var address: mach_vm_address_t = addr ?? 0

    if let addr, let totalSize {
        #if DEBUG
        print("[*] ellekit: Reusing page")
        #endif
        ptr = UnsafeMutableRawPointer(bitPattern: UInt(addr))?.advanced(by: totalSize)
    } else {
        mach_vm_allocate(mach_task_self_, &address, UInt64(vm_page_size), VM_FLAGS_ANYWHERE)
        mach_vm_protect(mach_task_self_, address, UInt64(vm_page_size), 0, VM_PROT_READ | VM_PROT_WRITE)
        ptr = UnsafeMutableRawPointer(bitPattern: UInt(address))
    }
    guard let ptr else { return (nil, 0) }

    unpatched = Array(unpatched.chunked(into: 4).rebind(
        formerPC: UInt64(UInt(bitPattern: target)),
        newPC: UInt64(UInt(bitPattern: ptr))).joined()
    )

    var code = [UInt8]()

    @InstructionBuilder
    var codeBuilder: [UInt8] {
        bytes(unpatched) // First instruction of the function that got hooked
        bytes(assembleJump(target_addr, pc: 0, link: false, big: true).dropLast(4))
        add(.x16, .x16, usedBigBranch ? 20 : 4) // Jump first instruction (the branch to the replacement)
        br(.x16)
    }

    code = codeBuilder

    let codesize = MemoryLayout<[UInt8]>.size * code.count

    if let totalSize {
        memcpy(ptr, code, codesize)
        #if DEBUG
        print("[+] ellekit: Orig written to:", ptr, "for function", totalSize)
        #endif
    } else {
        memcpy(ptr, code, codesize)
        mach_vm_protect(mach_task_self_, mach_vm_address_t(UInt(bitPattern: ptr)), UInt64(vm_page_size), 0, VM_PROT_READ | VM_PROT_EXECUTE)
        sys_icache_invalidate(ptr, Int(vm_page_size))
        #if DEBUG
        print("[+] ellekit: Orig written to:", ptr)
        #endif
    }
    return (ptr, codesize)
}
