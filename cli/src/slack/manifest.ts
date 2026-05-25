import { stringify } from "yaml";

export interface ManifestOptions {
  name?: string;
  displayName?: string;
}

/// Generate a modern Slack app manifest (v2 YAML) for the agents bridge. Socket
/// Mode (no public webhook), scoped to post and read messages in the channels
/// it is invited to (private channels use the `groups:*` scopes + message.groups).
export function slackAppManifest(opts: ManifestOptions = {}): string {
  const manifest = {
    display_information: {
      name: opts.name ?? "LangWatch Agents",
      description: "Observe and steer LangWatch's headless Claude Code agents",
      background_color: "#1a1a2e",
    },
    features: {
      bot_user: {
        display_name: opts.displayName ?? "langwatch-agents",
        always_online: true,
      },
    },
    oauth_config: {
      scopes: {
        bot: [
          "chat:write",
          "channels:history",
          "groups:history",
          "channels:read",
          "groups:read",
          "app_mentions:read",
          "users:read",
        ],
      },
    },
    settings: {
      event_subscriptions: {
        bot_events: ["message.channels", "message.groups", "app_mention"],
      },
      interactivity: { is_enabled: false },
      org_deploy_enabled: false,
      socket_mode_enabled: true,
      token_rotation_enabled: false,
    },
  };
  return stringify(manifest);
}

export const MANIFEST_INSTRUCTIONS = `To create the Slack app:
  1. Go to https://api.slack.com/apps  ->  "Create New App"  ->  "From a manifest"
  2. Pick the workspace, paste the manifest above, create the app.
  3. Under "Basic Information" -> "App-Level Tokens", generate a token with the
     "connections:write" scope. That is your SLACK_APP_TOKEN (xapp-...).
  4. Under "Install App", install to the workspace. Copy the Bot User OAuth Token.
     That is your SLACK_BOT_TOKEN (xoxb-...).
  5. Invite the bot to each agent's private channel: /invite @langwatch-agents
  6. Map each channel to an agent via the agents config (slackChannel: "#channel" or the channel id).`;
