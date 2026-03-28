package main

import (
	"fmt"
	"log"
	"net"
	"net/http"
	"os"

	"github.com/skip2/go-qrcode"
)

const (
	defaultPort    = "8080"
	envAnthropicKey = "ANTHROPIC_API_KEY"
	envVCDRAPIKey   = "VCDR_API_KEY"
	envPort         = "PORT"
)

func main() {
	anthropicKey := os.Getenv(envAnthropicKey)
	if anthropicKey == "" {
		log.Fatalf("%s is required", envAnthropicKey)
	}

	vcdrKey := os.Getenv(envVCDRAPIKey)
	if vcdrKey == "" {
		log.Fatalf("%s is required", envVCDRAPIKey)
	}

	port := os.Getenv(envPort)
	if port == "" {
		port = defaultPort
	}

	client := newAnthropicClient(anthropicKey)

	mux := http.NewServeMux()
	mux.HandleFunc("/health", healthHandler)
	mux.Handle("/v1/process", processHandler(client))

	handler := authMiddleware(vcdrKey, mux)

	addr := ":" + port
	log.Printf("VCDR Server starting on %s", addr)

	printConnectionInfo(port, vcdrKey)

	if err := http.ListenAndServe(addr, handler); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}

func printConnectionInfo(port, apiKey string) {
	ip := getLocalIP()
	host := fmt.Sprintf("%s:%s", ip, port)
	deeplink := fmt.Sprintf("vcdr://connect?host=%s&key=%s", host, apiKey)

	fmt.Println()
	fmt.Println("=== VCDR Server Connection ===")
	fmt.Printf("  Host: %s\n", host)
	fmt.Printf("  API Key: %s\n", apiKey)
	fmt.Printf("  Deeplink: %s\n", deeplink)
	fmt.Println()

	// QR code for iOS pairing — scan with camera to open deeplink
	qr, err := qrcode.New(deeplink, qrcode.Medium)
	if err != nil {
		log.Printf("Could not generate QR code: %v", err)
		return
	}
	fmt.Println("Scan this QR code with your iOS device:")
	fmt.Println(qr.ToSmallString(false))
}

func getLocalIP() string {
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return "localhost"
	}
	for _, addr := range addrs {
		if ipNet, ok := addr.(*net.IPNet); ok && !ipNet.IP.IsLoopback() && ipNet.IP.To4() != nil {
			return ipNet.IP.String()
		}
	}
	return "localhost"
}
