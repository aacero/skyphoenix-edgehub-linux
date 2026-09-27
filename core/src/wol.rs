//! Wake-on-LAN (WoL) packet construction and transmission.
//!
//! Provides magic packet creation (6 bytes of 0xFF followed by 16 repetitions of
//! the target MAC address) and broadcast transmission over UDP.

use std::net::UdpSocket;
use thiserror::Error;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum WolError {
    #[error("Invalid MAC address: {0}")]
    InvalidMac(String),
    #[error("Socket error: {0}")]
    IoError(String),
}

/// Parse a MAC address string into a 6-byte array.
///
/// Accepts standard colon-separated (`AA:BB:CC:DD:EE:FF`), hyphen-separated
/// (`AA-BB-CC-DD-EE-FF`), or bare hex string (`AABBCCDDEEFF`).
pub fn parse_mac(input: &str) -> Result<[u8; 6], WolError> {
    let clean = input.trim();
    let parts: Vec<&str> = if clean.contains(':') {
        clean.split(':').collect()
    } else if clean.contains('-') {
        clean.split('-').collect()
    } else {
        if clean.len() != 12 {
            return Err(WolError::InvalidMac(format!(
                "expected 12 hex characters without delimiters, got {}",
                clean.len()
            )));
        }
        let mut bytes = [0u8; 6];
        for i in 0..6 {
            bytes[i] = u8::from_str_radix(&clean[i * 2..i * 2 + 2], 16)
                .map_err(|e| WolError::InvalidMac(e.to_string()))?;
        }
        return Ok(bytes);
    };

    if parts.len() != 6 {
        return Err(WolError::InvalidMac(format!(
            "expected 6 octets, got {}",
            parts.len()
        )));
    }

    let mut bytes = [0u8; 6];
    for (i, part) in parts.iter().enumerate() {
        if part.len() != 2 {
            return Err(WolError::InvalidMac(format!(
                "octet {} is not 2 characters: '{}'",
                i, part
            )));
        }
        bytes[i] = u8::from_str_radix(part, 16)
            .map_err(|e| WolError::InvalidMac(format!("octet {}: {}", i, e)))?;
    }

    Ok(bytes)
}

/// Construct a 102-byte Wake-on-LAN magic packet.
///
/// The payload consists of 6 synchronization bytes (0xFF) followed by 16 repetitions
/// of the 6-byte target MAC address.
pub fn create_magic_packet(mac: &[u8; 6]) -> [u8; 102] {
    let mut packet = [0u8; 102];
    packet[..6].fill(0xFF);
    for i in 0..16 {
        let start = 6 + i * 6;
        packet[start..start + 6].copy_from_slice(mac);
    }
    packet
}

/// Send a Wake-on-LAN magic packet to the target MAC address.
///
/// If `broadcast_addr` is not specified or empty, defaults to `255.255.255.255`.
/// The destination port defaults to 9 (standard WoL port).
pub fn send_wol(
    mac_str: &str,
    broadcast_addr: Option<&str>,
    port: Option<u16>,
) -> Result<(), WolError> {
    let mac = parse_mac(mac_str)?;
    let packet = create_magic_packet(&mac);

    let host = match broadcast_addr {
        Some(h) if !h.trim().is_empty() => h.trim(),
        _ => "255.255.255.255",
    };
    let p = port.unwrap_or(9);

    let target = format!("{}:{}", host, p);

    let socket = UdpSocket::bind("0.0.0.0:0")
        .map_err(|e| WolError::IoError(format!("bind failed: {}", e)))?;
    socket
        .set_broadcast(true)
        .map_err(|e| WolError::IoError(format!("set_broadcast failed: {}", e)))?;

    socket
        .send_to(&packet, &target)
        .map_err(|e| WolError::IoError(format!("send_to {} failed: {}", target, e)))?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_mac_valid_formats() {
        let expected = [0x00, 0x11, 0x22, 0x33, 0x44, 0x55];

        assert_eq!(parse_mac("00:11:22:33:44:55").unwrap(), expected);
        assert_eq!(parse_mac("00-11-22-33-44-55").unwrap(), expected);
        assert_eq!(parse_mac("001122334455").unwrap(), expected);
        assert_eq!(parse_mac("  00:11:22:33:44:55  ").unwrap(), expected);

        // Case insensitivity
        let upper_expected = [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF];
        assert_eq!(parse_mac("aa:bb:cc:dd:ee:ff").unwrap(), upper_expected);
        assert_eq!(parse_mac("AA:BB:CC:DD:EE:FF").unwrap(), upper_expected);
        assert_eq!(parse_mac("aA:Bb:cC:Dd:eE:fF").unwrap(), upper_expected);
        assert_eq!(parse_mac("aabbccddeeff").unwrap(), upper_expected);
    }

    #[test]
    fn test_parse_mac_invalid_formats() {
        assert!(parse_mac("").is_err());
        assert!(parse_mac("00:11:22:33:44").is_err()); // 5 octets
        assert!(parse_mac("00:11:22:33:44:55:66").is_err()); // 7 octets
        assert!(parse_mac("00:11:22:33:44:ZZ").is_err()); // non-hex
        assert!(parse_mac("00:1:22:33:44:55").is_err()); // 1 char octet
        assert!(parse_mac("00112233445").is_err()); // 11 chars
        assert!(parse_mac("00112233445566").is_err()); // 14 chars
    }

    #[test]
    fn test_create_magic_packet_structure() {
        let mac = [0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC];
        let packet = create_magic_packet(&mac);

        assert_eq!(packet.len(), 102);

        // First 6 bytes are 0xFF
        assert_eq!(&packet[..6], &[0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]);

        // Followed by 16 repetitions of the MAC
        for i in 0..16 {
            let offset = 6 + i * 6;
            assert_eq!(
                &packet[offset..offset + 6],
                &mac,
                "repetition {} matches",
                i
            );
        }
    }

    #[test]
    fn test_send_wol_loopback() {
        // Bind a local receiver socket to loopback to verify transmission without leaving machine
        let receiver = UdpSocket::bind("127.0.0.1:0").expect("receiver socket bind");
        let recv_port = receiver.local_addr().unwrap().port();

        let mac_str = "00:11:22:33:44:55";
        let expected_mac = [0x00, 0x11, 0x22, 0x33, 0x44, 0x55];
        let expected_packet = create_magic_packet(&expected_mac);

        send_wol(mac_str, Some("127.0.0.1"), Some(recv_port)).expect("send_wol success");

        let mut buf = [0u8; 128];
        let (bytes_read, _src) = receiver.recv_from(&mut buf).expect("recv_from");

        assert_eq!(bytes_read, 102);
        assert_eq!(&buf[..102], &expected_packet[..]);
    }
}
