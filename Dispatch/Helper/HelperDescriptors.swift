#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

func renderer_configure(_ fd: Int32) -> Int32 {
    let flags = fcntl(fd, F_GETFL)
    let inherited = fcntl(fd, F_GETFD)
    guard flags >= 0, inherited >= 0,
        fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
        fcntl(fd, F_SETFD, inherited | FD_CLOEXEC) == 0
    else { return -1 }
    #if canImport(Darwin)
        var one: Int32 = 1
        if setsockopt(
            fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one))) != 0,
            errno != ENOTSOCK
        {
            return -1
        }
    #endif
    return 0
}

private func renderer_align(_ size: Int) -> Int {
    let alignment = MemoryLayout<cmsghdr>.alignment
    return (size + alignment - 1) & ~(alignment - 1)
}

private func renderer_message(
    _ bytes: UnsafeMutableRawPointer?, _ size: Int,
    _ call: (inout msghdr, UnsafeMutableRawBufferPointer) -> Int
) -> Int {
    let capacity =
        renderer_align(MemoryLayout<cmsghdr>.size)
        + renderer_align(2 * MemoryLayout<Int32>.size)
    var words = [UInt](
        repeating: 0, count: (capacity + MemoryLayout<UInt>.size - 1) / MemoryLayout<UInt>.size)
    return words.withUnsafeMutableBytes { control in
        var vector = iovec(iov_base: bytes, iov_len: size)
        return withUnsafeMutablePointer(to: &vector) { vector in
            var message = msghdr()
            message.msg_iov = vector
            message.msg_iovlen = 1
            message.msg_control = control.baseAddress
            message.msg_controllen = numericCast(capacity)
            return call(&message, control)
        }
    }
}

func renderer_send(
    _ fd: Int32, _ bytes: UnsafeRawPointer?, _ size: Int,
    _ descriptors: UnsafePointer<Int32>?, _ count: Int
) -> Int {
    guard count == 0 || count == 2, count == 0 || size > 0 else {
        errno = EINVAL
        return -1
    }
    return renderer_message(UnsafeMutableRawPointer(mutating: bytes), size) { message, control in
        if count == 0 {
            message.msg_control = nil
            message.msg_controllen = 0
        } else {
            let offset = renderer_align(MemoryLayout<cmsghdr>.size)
            let length = offset + count * MemoryLayout<Int32>.size
            var header = cmsghdr()
            header.cmsg_len = numericCast(length)
            header.cmsg_level = SOL_SOCKET
            header.cmsg_type = numericCast(SCM_RIGHTS)
            control.storeBytes(of: header, as: cmsghdr.self)
            control.baseAddress!.advanced(by: offset).copyMemory(
                from: descriptors!, byteCount: count * MemoryLayout<Int32>.size)
        }
        #if canImport(Darwin)
            return sendmsg(fd, &message, 0)
        #else
            return sendmsg(fd, &message, numericCast(MSG_NOSIGNAL))
        #endif
    }
}

func renderer_receive(
    _ fd: Int32, _ bytes: UnsafeMutableRawPointer?, _ size: Int,
    _ descriptors: UnsafeMutablePointer<Int32>, _ count: UnsafeMutablePointer<Int>
) -> Int {
    count.pointee = 0
    descriptors[0] = -1
    descriptors[1] = -1
    return renderer_message(bytes, size) { message, control in
        let result = recvmsg(fd, &message, 0)
        guard result > 0 else { return result }
        var invalid = message.msg_flags & (numericCast(MSG_CTRUNC) | numericCast(MSG_TRUNC)) != 0
        let used = Int(message.msg_controllen)
        let headerSize = renderer_align(MemoryLayout<cmsghdr>.size)
        var offset = 0
        for _ in 0..<used {
            guard used - offset >= MemoryLayout<cmsghdr>.size else { break }
            let header = control.loadUnaligned(fromByteOffset: offset, as: cmsghdr.self)
            let length = Int(header.cmsg_len)
            guard length >= headerSize, length <= used - offset else {
                invalid = true
                break
            }
            if header.cmsg_level == SOL_SOCKET && header.cmsg_type == SCM_RIGHTS {
                let payload = length - headerSize
                if payload % MemoryLayout<Int32>.size != 0 { invalid = true }
                for index in 0..<(payload / MemoryLayout<Int32>.size) {
                    let value = control.loadUnaligned(
                        fromByteOffset: offset + headerSize + index * MemoryLayout<Int32>.size,
                        as: Int32.self)
                    if count.pointee == 2 {
                        _ = close(value)
                        invalid = true
                    } else {
                        descriptors[count.pointee] = value
                        count.pointee += 1
                        if renderer_configure(value) != 0 { invalid = true }
                    }
                }
            } else {
                invalid = true
            }
            offset += renderer_align(length)
        }
        if count.pointee != 0 && count.pointee != 2 { invalid = true }
        guard invalid else { return result }
        for index in 0..<count.pointee {
            _ = close(descriptors[index])
            descriptors[index] = -1
        }
        count.pointee = 0
        errno = EPROTO
        return -1
    }
}
