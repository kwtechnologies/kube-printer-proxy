package main

import (
	"fmt"
	"io"
	"net"
	"os"
	"time"
)

func main() {
	ip := "192.168.50.130"
	if len(os.Args) > 1 {
		ip = os.Args[1]
	}

	zpl := "^XA^FO50,50^A0N,40,40^FDHello from Go^FS^XZ"

	addr := fmt.Sprintf("%s:9100", ip)
	fmt.Printf("Connecting to %s ...\n", addr)

	conn, err := net.DialTimeout("tcp", addr, 5*time.Second)
	if err != nil {
		fmt.Fprintf(os.Stderr, "FAIL connect: %v\n", err)
		os.Exit(1)
	}
	defer conn.Close()
	fmt.Println("Connected.")

	conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
	n, err := io.WriteString(conn, zpl)
	if err != nil {
		fmt.Fprintf(os.Stderr, "FAIL write: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("Wrote %d bytes of ZPL.\n", n)

	if tc, ok := conn.(*net.TCPConn); ok {
		fmt.Println("CloseWrite (sending TCP FIN) ...")
		tc.CloseWrite()
	}

	fmt.Println("Draining response (2s timeout) ...")
	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	resp, _ := io.ReadAll(conn)
	if len(resp) > 0 {
		fmt.Printf("Printer responded: %q\n", resp)
	} else {
		fmt.Println("No response from printer (normal for most Zebra printers).")
	}

	fmt.Println("Done. Check if the printer printed.")
}
