package netio

// Connection names, ported from net_multi.c's new_nhandle() and net_bsd_tcp.c's
// proto_accept_connection(): "port <listening port> from <host>, port <remote port>", where
// <host> is the remote address's name if a reverse lookup finds one, else its dotted form.
// connection_name() returns this, and core code parses it -- LambdaCore's
// $string_utils:connection_hostname and the site-lock checks in $login look for the text
// after "from " -- so the shape matters, not just the information.
//
// The original looks the name up synchronously in its accept path, stalling the whole server
// for up to $server_options.name_lookup_timeout seconds. Here accept_loop records the numeric
// form and the connection's own thread replaces it with the looked-up name (lookup_peer_name),
// so a slow resolver only delays that one connection.

import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:sys/posix"

// connection_name_for builds the name with the numeric host. Owned result.
connection_name_for :: proc(client, listener: net.TCP_Socket) -> string {
	local_port := 0
	if ep, err := net.bound_endpoint(listener); err == nil {
		local_port = ep.port
	}
	host := "unknown"
	remote_port := 0
	owned_host := ""
	if ep, err := net.peer_endpoint(client); err == nil {
		remote_port = ep.port
		owned_host = net.address_to_string(ep.address, context.allocator)
		host = owned_host
	}
	defer delete(owned_host)
	return fmt.aprintf("port %d from %s, port %d", local_port, host, remote_port)
}

// lookup_peer_name replaces conn.name's host with the peer's reverse-DNS name, if it has one.
// Runs on the connection's own thread before it reads any input.
lookup_peer_name :: proc(conn: ^Connection) {
	ep, err := net.peer_endpoint(conn.socket)
	if err != nil {
		return
	}
	ip4, is4 := ep.address.(net.IP4_Address)
	if !is4 {
		return
	}
	sa := posix.sockaddr_in{
		sin_family = .INET,
		sin_addr   = posix.in_addr{s_addr = transmute(posix.in_addr_t)ip4},
	}
	buf: [1025]byte
	if posix.getnameinfo(cast(^posix.sockaddr)&sa, size_of(sa), raw_data(buf[:]), len(buf), nil, 0, {.NAMEREQD}) != .NONE {
		return
	}
	host := strings.clone_from_cstring(cstring(raw_data(buf[:])))
	defer delete(host)
	local_port := 0
	if lep, lerr := net.bound_endpoint(conn.server.listener); lerr == nil {
		local_port = lep.port
	}
	name := fmt.aprintf("port %d from %s, port %d", local_port, host, ep.port)
	// conn.name is read by other threads under players_lock (hook_connection_name).
	sync.mutex_lock(&conn.server.players_lock)
	old := conn.name
	conn.name = name
	sync.mutex_unlock(&conn.server.players_lock)
	delete(old)
}
