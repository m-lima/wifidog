package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/prometheus-community/pro-bing"
)

func ping(targetIP string) bool {
	success := false
	pinger, err := probing.NewPinger(targetIP)
	if err != nil {
		fmt.Printf("Failed to create pinger: %v\n", err)
		os.Exit(1)
	}

	pinger.Timeout = time.Second * 10

	pinger.OnRecv = func(pkt *probing.Packet) {
		success = true
		pinger.Stop()
	}

	err = pinger.Run()
	if err != nil {
		fmt.Printf("Failed to run pinger: %v\n", err)
	}

	return success
}

func getSleep(failures int8) time.Duration {
	switch failures {
	case 0:
		return 15 * time.Second
	case 1:
		return 30 * time.Second
	case 2:
		return 60 * time.Second
	case 3:
		return 90 * time.Second
	case 4:
		return 2 * time.Minute
	default:
		return 5 * time.Minute
	}
}

func concatCmd(cmd string, args ...string) string {
	return strings.Join(append([]string{cmd}, args...), " ")
}

func reassociate(cmd string, args ...string) bool {
	fmt.Println("Reassociating")
	proc := exec.Command(cmd, args...)
	if err := proc.Run(); err != nil {
		fmt.Printf("Failed to call '%s': %v\n", concatCmd(cmd, args...), err)
		return false
	}
	return true
}

func main() {
	if len(os.Args) < 2 {
		fmt.Println("Missing target IP")
		os.Exit(1)
	}

	if len(os.Args) < 3 {
		fmt.Println("Missing reassociate command")
		os.Exit(1)
	}

	targetIP := os.Args[1]
	reassociateCmd := os.Args[2]
	reassociateCmdArgs := os.Args[3:]

	fmt.Printf("Starting wifi watchdog for '%s' with '%s'\n", targetIP, concatCmd(reassociateCmd, reassociateCmdArgs...))

	failures := int8(0)

	for {
		if ping(targetIP) {
			failures = 0
		} else {
			if reassociate(reassociateCmd, reassociateCmdArgs...) {
				if failures < 5 {
					failures++
				}
			} else {
				failures = 5
			}
		}
		time.Sleep(getSleep(failures))
	}
}
