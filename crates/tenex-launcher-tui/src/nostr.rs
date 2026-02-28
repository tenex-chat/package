use std::collections::HashMap;
use std::time::{Duration, Instant};

use anyhow::Result;
use nostr_sdk::{Client, Filter, Keys, Kind, RelayStatus, TagKind};

pub struct FetchedNudge {
    pub id: String,
    pub pubkey: String,
    pub d_tag: String,
    pub created_at: u64,
    pub title: String,
    pub description: String,
}

pub struct FetchedSkill {
    pub id: String,
    pub pubkey: String,
    pub d_tag: String,
    pub created_at: u64,
    pub title: String,
    pub description: String,
}

pub struct FetchResults {
    pub nudges: Vec<FetchedNudge>,
    pub skills: Vec<FetchedSkill>,
}

const NUDGE_KIND: u16 = 4201;
const SKILL_KIND: u16 = 4202;

fn tag_value(event: &nostr_sdk::Event, kind: TagKind) -> Option<String> {
    event
        .tags
        .find(kind)
        .and_then(|tag| tag.content().map(|s| s.to_string()))
}

/// Create a nostr client and connect to the given relays.
/// The caller is responsible for calling `client.disconnect().await` when done.
pub async fn connect(relay_urls: &[String], keys: Option<Keys>) -> Result<Client> {
    let client = match keys {
        Some(k) => Client::builder().signer(k).build(),
        None => Client::default(),
    };

    for url in relay_urls {
        client.add_relay(url.as_str()).await?;
    }

    client.connect().await;

    // connect() only spawns background tasks — poll until a relay is actually connected
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let relays = client.relays().await;
        let connected = relays
            .values()
            .any(|r| r.status() == RelayStatus::Connected);
        if connected {
            break;
        }
        if Instant::now() >= deadline {
            anyhow::bail!("Timed out waiting for relay connection");
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }

    Ok(client)
}

pub async fn fetch_events(client: &Client) -> Result<FetchResults> {
    let filter = Filter::new().kinds([
        Kind::from(NUDGE_KIND),
        Kind::from(SKILL_KIND),
    ]);

    let events = client
        .fetch_events(filter, Duration::from_secs(10))
        .await?;

    let mut nudges = Vec::new();
    let mut skills = Vec::new();

    for event in events.into_iter() {
        let id = event.id.to_hex();
        let kind_u16: u16 = event.kind.into();

        match kind_u16 {
            NUDGE_KIND => {
                let title = tag_value(&event, TagKind::Title)
                    .unwrap_or_else(|| "Unnamed Nudge".into());
                let description = tag_value(&event, TagKind::Description)
                    .unwrap_or_else(|| event.content.clone());
                let pubkey = event.pubkey.to_hex();
                let d_tag = tag_value(
                    &event,
                    TagKind::SingleLetter(nostr_sdk::SingleLetterTag::lowercase(
                        nostr_sdk::Alphabet::D,
                    )),
                )
                .unwrap_or_default();
                let created_at = event.created_at.as_secs();

                nudges.push(FetchedNudge {
                    id,
                    pubkey,
                    d_tag,
                    created_at,
                    title,
                    description,
                });
            }
            SKILL_KIND => {
                let title = tag_value(&event, TagKind::Title)
                    .unwrap_or_else(|| "Unnamed Skill".into());
                let description = tag_value(&event, TagKind::Description)
                    .unwrap_or_default();
                let pubkey = event.pubkey.to_hex();
                let d_tag = tag_value(
                    &event,
                    TagKind::SingleLetter(nostr_sdk::SingleLetterTag::lowercase(
                        nostr_sdk::Alphabet::D,
                    )),
                )
                .unwrap_or_default();
                let created_at = event.created_at.as_secs();

                skills.push(FetchedSkill {
                    id,
                    pubkey,
                    d_tag,
                    created_at,
                    title,
                    description,
                });
            }
            _ => {}
        }
    }

    let nudges = dedup_by_pubkey_dtag_nudges(nudges);
    let skills = dedup_by_pubkey_dtag_skills(skills);

    Ok(FetchResults {
        nudges,
        skills,
    })
}

/// Keep only the latest nudge per (pubkey, d_tag). Events without a d_tag are kept as-is.
fn dedup_by_pubkey_dtag_nudges(nudges: Vec<FetchedNudge>) -> Vec<FetchedNudge> {
    let mut latest: HashMap<(String, String), FetchedNudge> = HashMap::new();
    let mut no_dtag: Vec<FetchedNudge> = Vec::new();
    for nudge in nudges {
        if nudge.d_tag.is_empty() {
            no_dtag.push(nudge);
            continue;
        }
        let key = (nudge.pubkey.clone(), nudge.d_tag.clone());
        let replace = latest.get(&key).map_or(true, |e| nudge.created_at > e.created_at);
        if replace {
            latest.insert(key, nudge);
        }
    }
    let mut result: Vec<FetchedNudge> = latest.into_values().collect();
    result.extend(no_dtag);
    result
}

/// Keep only the latest skill per (pubkey, d_tag). Events without a d_tag are kept as-is.
fn dedup_by_pubkey_dtag_skills(skills: Vec<FetchedSkill>) -> Vec<FetchedSkill> {
    let mut latest: HashMap<(String, String), FetchedSkill> = HashMap::new();
    let mut no_dtag: Vec<FetchedSkill> = Vec::new();
    for skill in skills {
        if skill.d_tag.is_empty() {
            no_dtag.push(skill);
            continue;
        }
        let key = (skill.pubkey.clone(), skill.d_tag.clone());
        let replace = latest.get(&key).map_or(true, |e| skill.created_at > e.created_at);
        if replace {
            latest.insert(key, skill);
        }
    }
    let mut result: Vec<FetchedSkill> = latest.into_values().collect();
    result.extend(no_dtag);
    result
}
