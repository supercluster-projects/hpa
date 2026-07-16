import socket
import threading
import sys

def forward(src_sock, dst_ip, dst_port):
    try:
        dst_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        dst_sock.connect((dst_ip, dst_port))
    except Exception as e:
        src_sock.close()
        return

    def pipe(src, dst):
        try:
            while True:
                data = src.recv(4096)
                if not data:
                    break
                dst.sendall(data)
        except Exception:
            pass
        finally:
            src.close()
            dst.close()

    threading.Thread(target=pipe, args=(src_sock, dst_sock), daemon=True).start()
    threading.Thread(target=pipe, args=(dst_sock, src_sock), daemon=True).start()

def main():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        server.bind(('192.168.122.1', 10809))
        server.listen(100)
    except Exception as e:
        print(f"Error binding to port 10809: {e}", file=sys.stderr)
        sys.exit(1)

    print("Forwarding 192.168.122.1:10809 -> 127.0.0.1:10809")
    try:
        while True:
            client_sock, addr = server.accept()
            forward(client_sock, '127.0.0.1', 10809)
    except KeyboardInterrupt:
        pass
    finally:
        server.close()

if __name__ == '__main__':
    main()
