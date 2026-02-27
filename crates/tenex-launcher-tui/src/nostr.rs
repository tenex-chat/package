use std::collections::HashMap;
use std::time::{Duration, Instant};

use anyhow::Result;
use nostr_sdk::{Client, Filter, Kind, RelayStatus, TagKind};

pub struct FetchedTeam {
    pub id: String,
    pub title: String,
    pub description: String,
    /// Event IDs of the agents in this team.
    pub agent_event_ids: Vec<String>,
}

pub struct FetchedAgent {
    pub id: String,
    pub name: String,
    pub role: String,
    pub description: String,
    /// Raw serialized Nostr event JSON — used for piping to `tenex agent add` via stdin.
    pub raw_json: String,
}

pub struct FetchedNudge {
    pub id: String,
    pub title: String,
    pub description: String,
}

pub struct FetchedSkill {
    pub id: String,
    pub title: String,
    pub description: String,
}

pub struct FetchResults {
    pub teams: Vec<FetchedTeam>,
    pub agents: Vec<FetchedAgent>,
    pub nudges: Vec<FetchedNudge>,
    pub skills: Vec<FetchedSkill>,
}

impl FetchResults {
    /// Resolve a team's agent references to actual FetchedAgent entries.
    pub fn agents_for_team(&self, team: &FetchedTeam) -> Vec<&FetchedAgent> {
        let agent_index: HashMap<&str, &FetchedAgent> =
            self.agents.iter().map(|a| (a.id.as_str(), a)).collect();
        team.agent_event_ids
            .iter()
            .filter_map(|eid| agent_index.get(eid.as_str()).copied())
            .collect()
    }
}

const TEAM_KIND: u16 = 34199;
const AGENT_KIND: u16 = 4199;
const NUDGE_KIND: u16 = 4201;
const SKILL_KIND: u16 = 4202;

fn tag_value(event: &nostr_sdk::Event, kind: TagKind) -> Option<String> {
    event
        .tags
        .find(kind)
        .and_then(|tag| tag.content().map(|s| s.to_string()))
}

/// Collect all `e` tag values from an event (agent references in a team).
fn e_tag_values(event: &nostr_sdk::Event) -> Vec<String> {
    event
        .tags
        .iter()
        .filter(|t| t.kind() == TagKind::SingleLetter(nostr_sdk::SingleLetterTag::lowercase(nostr_sdk::Alphabet::E)))
        .filter_map(|t| t.content().map(|s| s.to_string()))
        .collect()
}

pub async fn fetch_from_relays(relay_urls: &[String]) -> Result<FetchResults> {
    let client = Client::default();

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

    let filter = Filter::new().kinds([
        Kind::from(TEAM_KIND),
        Kind::from(AGENT_KIND),
        Kind::from(NUDGE_KIND),
        Kind::from(SKILL_KIND),
    ]);

    let events = client
        .fetch_events(filter, Duration::from_secs(10))
        .await?;

    let mut teams = Vec::new();
    let mut agents = Vec::new();
    let mut nudges = Vec::new();
    let mut skills = Vec::new();

    for event in events.into_iter() {
        let id = event.id.to_hex();
        let kind_u16: u16 = event.kind.into();

        match kind_u16 {
            TEAM_KIND => {
                let title = tag_value(&event, TagKind::Title).unwrap_or_default();
                if title.is_empty() {
                    continue;
                }
                let description = if event.content.is_empty() {
                    tag_value(&event, TagKind::Description).unwrap_or_default()
                } else {
                    event.content.clone()
                };
                let agent_event_ids = e_tag_values(&event);
                teams.push(FetchedTeam {
                    id,
                    title,
                    description,
                    agent_event_ids,
                });
            }
            AGENT_KIND => {
                let name = tag_value(&event, TagKind::Title)
                    .unwrap_or_else(|| "Unnamed Agent".into());
                let role = tag_value(&event, TagKind::Custom("role".into()))
                    .unwrap_or_default();
                let description = tag_value(&event, TagKind::Description)
                    .unwrap_or_else(|| event.content.clone());
                let raw_json = serde_json::to_string(&event).unwrap_or_default();

                agents.push(FetchedAgent {
                    id,
                    name,
                    role,
                    description,
                    raw_json,
                });
            }
            NUDGE_KIND => {
                let title = tag_value(&event, TagKind::Title)
                    .unwrap_or_else(|| "Unnamed Nudge".into());
                let description = tag_value(&event, TagKind::Description)
                    .unwrap_or_else(|| event.content.clone());

                nudges.push(FetchedNudge {
                    id,
                    title,
                    description,
                });
            }
            SKILL_KIND => {
                let title = tag_value(&event, TagKind::Title)
                    .unwrap_or_else(|| "Unnamed Skill".into());
                let description = tag_value(&event, TagKind::Description)
                    .unwrap_or_default();

                skills.push(FetchedSkill {
                    id,
                    title,
                    description,
                });
            }
            _ => {}
        }
    }

    client.disconnect().await;

    Ok(FetchResults {
        teams,
        agents,
        nudges,
        skills,
    })
}
