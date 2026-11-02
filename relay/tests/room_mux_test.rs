mod common;
use common::{connect_and_auth, connect_and_auth_with_room};

use ed25519_dalek::SigningKey;
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio::time::{Duration, timeout};
use tokio_tungstenite::tungstenite::Message;

async fn next_json(ws: &mut common::WsStream) -> Value {
    let msg = timeout(Duration::from_secs(1), ws.next())
        .await
        .expect("timed out")
        .unwrap()
        .unwrap();
    serde_json::from_str(msg.to_text().unwrap()).unwrap()
}

/// One host socket serves two rooms: frames for either room arrive on it with
/// `to_room`, and its replies carry the room it names in `from_room`.
#[tokio::test]
async fn one_socket_serves_several_rooms() {
    let port = common::start_relay().await;
    let host_key = SigningKey::generate(&mut rand::thread_rng());
    let (mut host, host_pk) = connect_and_auth_with_room(port, &host_key, "roomA").await;
    let (mut phone, phone_pk) = connect_and_auth(port).await;

    host.send(Message::text(
        json!({"type": "room_open", "room_id": "roomB", "room_meta": {"name": "B"}}).to_string(),
    ))
    .await
    .unwrap();
    assert_eq!(
        next_json(&mut host).await,
        json!({"type": "room_opened", "room_id": "roomB"})
    );

    for room in ["roomA", "roomB"] {
        phone
            .send(Message::text(
                json!({"peer": host_pk, "room": room, "ct": "AA=="}).to_string(),
            ))
            .await
            .unwrap();
        let got = next_json(&mut host).await;
        assert_eq!(got["to_room"], room);
        assert_eq!(got["peer"], phone_pk);
    }

    host.send(Message::text(
        json!({"peer": phone_pk, "from_room": "roomB", "ct": "AQ=="}).to_string(),
    ))
    .await
    .unwrap();
    assert_eq!(next_json(&mut phone).await["room"], "roomB");

    // A room the socket does not own cannot be claimed as the sender.
    host.send(Message::text(
        json!({"peer": phone_pk, "from_room": "elsewhere", "ct": "Ag=="}).to_string(),
    ))
    .await
    .unwrap();
    assert_eq!(next_json(&mut phone).await["room"], "roomA");

    // Closing a room stops delivery to it.
    host.send(Message::text(
        json!({"type": "room_close", "room_id": "roomB"}).to_string(),
    ))
    .await
    .unwrap();
    tokio::time::sleep(Duration::from_millis(50)).await;
    phone
        .send(Message::text(
            json!({"peer": host_pk, "room": "roomB", "ct": "AA=="}).to_string(),
        ))
        .await
        .unwrap();
    assert!(
        timeout(Duration::from_millis(200), host.next())
            .await
            .is_err()
    );
}
