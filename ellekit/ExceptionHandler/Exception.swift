import Foundation
import Darwin

#if SWIFT_PACKAGE
import ellekitc
#endif

#if arch(x86_64)
let ARM_THREAD_STATE64_COUNT = 0
#else
let ARM_THREAD_STATE64_COUNT = MemoryLayout<arm_thread_state64_t>.size/MemoryLayout<UInt32>.size
#endif

var closeExceptionPort = false

public final class ExceptionHandler {

    let port: mach_port_t
    let thread = DispatchQueue(label: "ellekit_exc_port", attributes: .concurrent)

    public init() {
        var targetPort = mach_port_t()

        mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &targetPort)
        mach_port_insert_right(mach_task_self_, targetPort, targetPort, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND))

        #if arch(arm64) || _ptrauth(_arm64e)
        task_set_exception_ports(
            mach_task_self_,
            exception_mask_t(EXC_MASK_BREAKPOINT),
            targetPort,
            EXCEPTION_DEFAULT,
            ARM_THREAD_STATE64
        )
        #endif

        self.port = targetPort

        startPortLoop()
    }

    public func startPortLoop() {
        #if DEBUG
        print("[+] ellekit: starting exception handler")
        #endif
        self.thread.async { [weak self] in
            Self.portLoop(self)
        }
    }

    static func portLoop(_ `self`: ExceptionHandler?) {

        guard let `self` else {
            if #available(iOS 14.0, macOS 11.0, *) {
                logger.error("ellekit: exception handler deallocated.")
            }
            print("[-] ellekit: exception handler deallocated.")
            return
        }

        let msg_header = UnsafeMutablePointer<mach_msg_header_t>.allocate(capacity: Int(vm_page_size))

        defer { msg_header.deallocate() }

        let krt1 = mach_msg(
            msg_header,
            MACH_RCV_MSG | MACH_RCV_LARGE | Int32(MACH_MSG_TIMEOUT_NONE),
            0,
            mach_msg_size_t(vm_page_size),
            self.port,
            0,
            0
        )

        guard krt1 == KERN_SUCCESS else {
            if #available(iOS 14.0, macOS 11.0, *) {
                logger.error("ellekit: couldn't receive from port")
            }
            print("[-] couldn't receive from port:", mach_error_string(krt1) ?? "")
            return
        }

        let req = UnsafeMutableRawPointer(msg_header)
            .makeReadable()
            .withMemoryRebound(to: exception_raise_request.self, capacity: Int(vm_page_size)) { $0.pointee }

        let thread_port = req.thread.name

        defer {
            var reply = exception_raise_reply()
            reply.Head.msgh_bits = req.Head.msgh_bits & UInt32(MACH_MSGH_BITS_REMOTE_MASK)
            reply.Head.msgh_size = mach_msg_size_t(MemoryLayout.size(ofValue: reply))
            reply.Head.msgh_remote_port = req.Head.msgh_remote_port
            reply.Head.msgh_local_port = mach_port_t(MACH_PORT_NULL)
            reply.Head.msgh_id = req.Head.msgh_id + 0x64

            reply.NDR = req.NDR
            reply.RetCode = KERN_SUCCESS

            let krt = mach_msg(
                &reply.Head,
                1,
                reply.Head.msgh_size,
                0,
                mach_port_name_t(MACH_PORT_NULL),
                MACH_MSG_TIMEOUT_NONE,
                mach_port_name_t(MACH_PORT_NULL)
            )

            if krt != KERN_SUCCESS {
                if #available(iOS 14.0, macOS 11.0, *) {
                    logger.notice("error sending reply to exception")
                }
                print("[-] error sending reply to exception: ", mach_error_string(krt) ?? "")
            }

            Self.portLoop(self)
        }

        #if arch(x86_64)
        #else

        var state = arm_thread_state64()
        var stateCnt = mach_msg_type_number_t(ARM_THREAD_STATE64_COUNT)

        let krt2 = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: UInt32.self, capacity: MemoryLayout<arm_thread_state64>.size) {
                thread_get_state(thread_port, ARM_THREAD_STATE64, $0, &stateCnt)
            }
        }

        guard krt2 == KERN_SUCCESS else {
            if #available(iOS 14.0, macOS 11.0, *) {
                logger.error("ellekit: couldn't get state for thread")
            }
            print("[-] couldn't get state for thread:", mach_error_string(krt1) ?? "")
            return
        }

        #if _ptrauth(_arm64e)
        guard let formerPtr = state.__opaque_pc?.makeReadable() else {
            if #available(iOS 14.0, macOS 11.0, *) {
                logger.error("couldn't get ptr from pc reg")
            }
            print("[-] couldn't get ptr from pc reg")
            return
        }
        #else
        guard let formerPtr = UnsafeMutableRawPointer(bitPattern: UInt(state.__pc)) else {
            if #available(iOS 14.0, macOS 11.0, *) {
                logger.error("couldn't get ptr from pc reg")
            }
            print("[-] couldn't get ptr from pc reg")
            return
        }
        #endif

        if let newPtr = hooks[formerPtr] ?? hooks.first?.value {

            #if _ptrauth(_arm64e)
            state.__opaque_pc = sign_pc(newPtr)
            state.__x.16 = UInt64(UInt(bitPattern: sign_pc(newPtr)))
            #else
            state.__pc = UInt64(UInt(bitPattern: newPtr))
            state.__x.16 = UInt64(UInt(bitPattern: newPtr))
            #endif

            let krt_set = withUnsafeMutablePointer(to: &state, {
                $0.withMemoryRebound(to: UInt32.self, capacity: MemoryLayout<arm_thread_state64>.size, {
                    thread_set_state(thread_port, ARM_THREAD_STATE64, $0, mach_msg_type_number_t(ARM_THREAD_STATE64_COUNT))
                })
            })

            guard krt_set == KERN_SUCCESS else {
                if #available(iOS 14.0, macOS 11.0, *) {
                    logger.error("ellekit: couldn't set state for thread")
                }
                print("[-] couldn't set state for thread:", mach_error_string(krt1) ?? "")
                return
            }

        } else {
            thread_suspend(thread_port)
            mach_port_deallocate(mach_task_self_, thread_port)
            return
        }
        #endif

        thread_resume(thread_port)

        return
    }
}
