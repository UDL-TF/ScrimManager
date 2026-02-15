#include <sourcemod>
#include <adt_array>

#include "include/env_variables"

#define DATABASE_CONFIG            "scrimmanager"
#define MAX_ENV_VALUE              2048
#define MAX_OWNER_ENTRIES          64
#define MAX_STEAMID64_LENGTH       32
#define MAX_SERVER_ID_LENGTH       64
#define MAX_PASSWORD_LENGTH        128

ArrayList OwnerSteamIds = null;
ConVar SvPassword = null;
Database DB = null;

char ServerId[MAX_SERVER_ID_LENGTH];
bool ServerIdPresent = false;
bool DatabaseReady = false;

public Plugin myinfo =
{
	name = "ScrimManager",
	author = "Tolfx",
	description = "Scrim owners + password coordinator",
	version = "1.0.0",
	url = "https://github.com/UDL-TF/ScrimManager"
};

public void OnPluginStart()
{
	SvPassword = FindConVar("sv_password");
	if (SvPassword == null)
	{
		SetFailState("Unable to find sv_password cvar");
	}

	LoadServerIdFromEnv();
	LoadOwnersFromEnv();
	ConnectToPasswordDatabase();

	RegAdminCmd("sm_password", CommandSetPassword, ADMFLAG_ROOT,
				"Sets the scrim password and persists it (usage: /password <value>)");
}

public void OnPluginEnd()
{
	if (DB != null)
	{
		delete DB;
		DB = null;
	}

	if (OwnerSteamIds != null)
	{
		delete OwnerSteamIds;
		OwnerSteamIds = null;
	}
}

public void OnConfigsExecuted()
{
	if (DatabaseReady)
	{
		LoadStoredPassword();
	}
}

public void OnClientPostAdminCheck(int client)
{
	if (!IsClientInGame(client) || IsFakeClient(client) || OwnerSteamIds == null)
	{
		return;
	}

	char authId[MAX_STEAMID64_LENGTH];
	if (!GetClientAuthId(client, AuthId_SteamID64, authId, sizeof(authId)))
	{
		return;
	}

	if (!IsOwnerSteamId(authId))
	{
		return;
	}

	int flags = GetUserFlagBits(client);
	if ((flags & ADMFLAG_ROOT) == ADMFLAG_ROOT)
	{
		return;
	}

	SetUserFlagBits(client, flags | ADMFLAG_ROOT);
	LogAction(client, -1, "[ScrimManager] Granted root access via SCRIM_OWNERS list");
}

static void LoadServerIdFromEnv()
{
	bool exists = false;
	GetEnvironmentVariable("SERVER_ID", ServerId, sizeof(ServerId), exists);

	if (!exists)
	{
		ServerId[0] = '\0';
		ServerIdPresent = false;
		LogError("SERVER_ID environment variable is not set; password persistence is disabled");
		return;
	}

	TrimString(ServerId);

	if (ServerId[0] == '\0')
	{
		ServerIdPresent = false;
		LogError("SERVER_ID environment variable is empty; password persistence is disabled");
		return;
	}

	ServerIdPresent = true;
	LogMessage("Loaded SERVER_ID '%s'", ServerId);
}

static void LoadOwnersFromEnv()
{
	if (OwnerSteamIds != null)
	{
		delete OwnerSteamIds;
	}

	OwnerSteamIds = new ArrayList(MAX_STEAMID64_LENGTH);

	char envValue[MAX_ENV_VALUE];
	bool exists = false;
	GetEnvironmentVariable("SCRIM_OWNERS", envValue, sizeof(envValue), exists);

	if (!exists)
	{
		LogMessage("SCRIM_OWNERS environment variable not found; no automatic root owners configured");
		return;
	}

	TrimString(envValue);

	if (envValue[0] == '\0')
	{
		LogMessage("SCRIM_OWNERS environment variable is empty; no owners configured");
		return;
	}

	char owners[MAX_OWNER_ENTRIES][MAX_STEAMID64_LENGTH];
	int count = ExplodeString(envValue, ",", owners, MAX_OWNER_ENTRIES, sizeof(owners[]));

	if (count == 0)
	{
		LogMessage("SCRIM_OWNERS contained no usable entries");
		return;
	}

	if (count == MAX_OWNER_ENTRIES)
	{
		LogError("SCRIM_OWNERS exceeded %d entries; extra values were ignored", MAX_OWNER_ENTRIES);
	}

	for (int i = 0; i < count; i++)
	{
		TrimString(owners[i]);
		if (owners[i][0] == '\0')
		{
			continue;
		}

		OwnerSteamIds.PushString(owners[i]);
		LogMessage("Registered SCRIM owner %s", owners[i]);
	}
}

static bool IsOwnerSteamId(const char[] steamId64)
{
	if (OwnerSteamIds == null)
	{
		return false;
	}

	int count = OwnerSteamIds.Length;
	for (int i = 0; i < count; i++)
	{
		char stored[MAX_STEAMID64_LENGTH];
		OwnerSteamIds.GetString(i, stored, sizeof(stored));
		if (StrEqual(stored, steamId64, false))
		{
			return true;
		}
	}

	return false;
}

static void ConnectToPasswordDatabase()
{
	Database.Connect(OnDatabaseConnected, DATABASE_CONFIG);
}

public void OnDatabaseConnected(Database db, const char[] error, any data)
{
	if (db == null)
	{
		LogError("Failed to connect to database '%s': %s", DATABASE_CONFIG, error);
		return;
	}

	if (DB != null)
	{
		delete DB;
	}

	DB = db;

	static const char query[] = "CREATE TABLE IF NOT EXISTS scrim_passwords (server_id VARCHAR(64) PRIMARY KEY, password VARCHAR(255) NOT NULL)";

	DB.Query(OnPasswordTableReady, query);
}

public void OnPasswordTableReady(Database db, DBResultSet results, const char[] error, any data)
{
	if (error[0] != '\0')
	{
		LogError("Failed to ensure scrim_passwords table exists: %s", error);
		return;
	}

	DatabaseReady = true;
	LogMessage("scrim_passwords table ready");
	LoadStoredPassword();
}

static void LoadStoredPassword()
{
	if (!DatabaseReady || !ServerIdPresent)
	{
		return;
	}

	char escapedId[MAX_SERVER_ID_LENGTH * 2];
	DB.Escape(ServerId, escapedId, sizeof(escapedId));

	char query[256];
	Format(query, sizeof(query),
		   "SELECT password FROM scrim_passwords WHERE server_id = '%s' LIMIT 1",
		   escapedId);

	DB.Query(OnPasswordLoaded, query);
}

public void OnPasswordLoaded(Database db, DBResultSet results, const char[] error, any data)
{
	if (error[0] != '\0' || results == null)
	{
		LogError("Failed to load stored password: %s", error);
		return;
	}

	if (!results.FetchRow())
	{
		LogMessage("No stored password found for server_id '%s'", ServerId);
		return;
	}

	char password[MAX_PASSWORD_LENGTH];
	results.FetchString(0, password, sizeof(password));

	if (password[0] == '\0')
	{
		return;
	}

	SvPassword.SetString(password, true, true);
	LogMessage("Applied stored password for server_id '%s'", ServerId);
}

static void PersistPassword(const char[] password)
{
	if (!DatabaseReady || !ServerIdPresent)
	{
		return;
	}

	char escapedPassword[MAX_PASSWORD_LENGTH * 2];
	char escapedId[MAX_SERVER_ID_LENGTH * 2];
	DB.Escape(password, escapedPassword, sizeof(escapedPassword));
	DB.Escape(ServerId, escapedId, sizeof(escapedId));

	char query[512];
	Format(query, sizeof(query),
		   "REPLACE INTO scrim_passwords (server_id, password) VALUES ('%s', '%s')",
		   escapedId, escapedPassword);

	DB.Query(OnPasswordSaved, query);
}

public void OnPasswordSaved(Database db, DBResultSet results, const char[] error, any data)
{
	if (error[0] != '\0')
	{
		LogError("Failed to persist scrim password: %s", error);
		return;
	}

	LogMessage("Scrim password updated in database for server_id '%s'", ServerId);
}

public Action CommandSetPassword(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "[ScrimManager] Usage: /password <new_password>");
		return Plugin_Handled;
	}

	char password[MAX_PASSWORD_LENGTH];
	GetCmdArg(1, password, sizeof(password));
	StripQuotes(password);
	TrimString(password);

	if (password[0] == '\0')
	{
		ReplyToCommand(client, "[ScrimManager] Password cannot be empty");
		return Plugin_Handled;
	}

	SvPassword.SetString(password, true, true);

	if (DatabaseReady && ServerIdPresent)
	{
		PersistPassword(password);
		ReplyToCommand(client, "[ScrimManager] Password updated and saved");
	}
	else
	{
		ReplyToCommand(client,
					   "[ScrimManager] Password updated locally but could not be saved (missing DB connection or SERVER_ID)");
	}

	return Plugin_Handled;
}
