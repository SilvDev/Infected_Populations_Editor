/*
*	Infected Populations Editor
*	Copyright (C) 2024 Silvers
*
*	This program is free software: you can redistribute it and/or modify
*	it under the terms of the GNU General Public License as published by
*	the Free Software Foundation, either version 3 of the License, or
*	(at your option) any later version.
*
*	This program is distributed in the hope that it will be useful,
*	but WITHOUT ANY WARRANTY; without even the implied warranty of
*	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
*	GNU General Public License for more details.
*
*	You should have received a copy of the GNU General Public License
*	along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/



#define PLUGIN_VERSION		"1.3"

/*======================================================================================
	Plugin Info:

*	Name	:	[L4D2] Infected Populations Editor
*	Author	:	SilverShot
*	Descrp	:	Modify population.txt values by config instead of conflicting VPK files.
*	Link	:	https://forums.alliedmods.net/showthread.php?t=344298
*	Plugins	:	https://sourcemod.net/plugins.php?exact=exact&sortby=title&search=1&author=Silvers

========================================================================================
	Change Log:

1.3 (05-Mar-2024)
	- Added support for Special Infected NavArea placements. Requested by "Sev".
	- Plugin now requires the "Left 4 DHooks" plugin.
	- GameData file has been updated.

1.2 (07-Nov-2023)
	- Added feature to load configs by base mode: "coop", "realism", "survival", "versus", "scavenge" or defaults to "file" within the data config.
	- Added "population3.txt" scripts config example to spawn all types of available infected.

1.1 (26-Oct-2023)
	- Ignores non-common infected spawn areas allowing Special Infected to spawn.

1.0 (25-Oct-2023)
	- Initial release.

======================================================================================*/

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <dhooks>
#include <left4dhooks>


#define CVAR_FLAGS			FCVAR_NOTIFY
#define GAMEDATA			"l4d_population_editor"
#define CONFIG_DATA			"data/l4d_population_editor.cfg"
#define DEBUG_PRINT			0 // Debug print the models loaded, the chance etc


ConVar g_hCvarMPGameMode;
int g_iCurrentMode;
bool g_bValidData;
StringMap g_hData;
StringMapSnapshot g_hSnap;
Address g_aPatchConfig;
Handle g_hSDK_ReloadPopulation;

enum
{
	TYPE_CEDA			= 11,
	TYPE_MUD_MEN		= 12,
	TYPE_ROAD_WORKER	= 13,
	TYPE_FALLEN			= 14,
	TYPE_RIOT			= 15,
	TYPE_CLOWN			= 16,
	TYPE_JIMMY_GIBBS	= 17
}



// ====================================================================================================
//					PLUGIN INFO / NATIVES
// ====================================================================================================
public Plugin myinfo =
{
	name = "[L4D2] Infected Populations Editor",
	author = "SilverShot",
	description = "Modify population.txt values by config instead of conflicting VPK files.",
	version = PLUGIN_VERSION,
	url = "https://forums.alliedmods.net/showthread.php?t=344298"
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	EngineVersion test = GetEngineVersion();
	if( test != Engine_Left4Dead2 )
	{
		strcopy(error, err_max, "Plugin only supports Left 4 Dead 2.");
		return APLRes_SilentFailure;
	}

	return APLRes_Success;
}



// ====================================================================================================
//					PLUGIN START / END
// ====================================================================================================
public void OnPluginStart()
{
	// =========================
	// GAMEDATA
	// =========================
	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), "gamedata/%s.txt", GAMEDATA);
	if( FileExists(sPath) == false ) SetFailState("\n==========\nMissing required file: \"%s\".\nRead installation instructions again.\n==========", sPath);

	GameData hGameData = LoadGameConfigFile(GAMEDATA);
	if( hGameData == null ) SetFailState("Failed to load \"%s.txt\" gamedata.", GAMEDATA);



	// =========================
	// SDKCALL
	// =========================
	StartPrepSDKCall(SDKCall_Raw);
	PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, "CDirector::ReloadPopulationData");
	g_hSDK_ReloadPopulation = EndPrepSDKCall();



	// =========================
	// ADDRESSES
	// =========================
	g_aPatchConfig = GameConfGetAddress(hGameData, "PatchPopConfig") + view_as<Address>(8);



	// =========================
	// DETOURS
	// =========================
	Handle hDetour;

	// Spawn by population:
	hDetour = DHookCreateFromConf(hGameData, "SelectModelByPopulation");
	if( !hDetour )
		SetFailState("Failed to find \"SelectModelByPopulation\" signature.");
	if( !DHookEnableDetour(hDetour, false, SelectModelByPopulation) )
		SetFailState("Failed to detour \"SelectModelByPopulation\"");
	delete hDetour;

	delete hGameData;

	// Uncommon infected spawns:
	/*
	hDetour = DHookCreateFromConf(hGameData, "Infected::Spawn");
	if( !hDetour )
		SetFailState("Failed to find \"Infected::Spawn\" signature.");
	if( !DHookEnableDetour(hDetour, false, Infected_Spawn) )
		SetFailState("Failed to detour \"Infected::Spawn\"");
	if( !DHookEnableDetour(hDetour, true, Infected_Spawn_Post) )
		SetFailState("Failed to detour \"Infected::Spawn\"");
	delete hDetour;
	*/



	// =========================
	// OTHER
	// =========================
	g_hCvarMPGameMode = FindConVar("mp_gamemode");
	g_hCvarMPGameMode.AddChangeHook(ConVarChanged_Cvars);

	CreateConVar("l4d_population_editor_version", PLUGIN_VERSION, "Infected Populations Editor plugin version.", FCVAR_NOTIFY|FCVAR_DONTRECORD);

	RegAdminCmd("sm_pop_reload", CmdReload, ADMFLAG_ROOT, "Reloads the Infected Populations Editor data config.");

	g_hData = new StringMap();
}



// ====================================================================================================
// LOAD CONFIG
// ====================================================================================================
Action CmdReload(int client, int args)
{
	LoadConfig();

	ReplyToCommand(client, "Population Editor: config reloaded!");

	return Plugin_Handled;
}

public void OnMapStart()
{
	GetGameMode();

	LoadConfig();
}

void GetGameMode()
{
	g_iCurrentMode = 0;

	int entity = CreateEntityByName("info_gamemode");
	if( IsValidEntity(entity) )
	{
		DispatchSpawn(entity);
		HookSingleEntityOutput(entity, "OnCoop", OnGamemode, true);
		HookSingleEntityOutput(entity, "OnSurvival", OnGamemode, true);
		HookSingleEntityOutput(entity, "OnVersus", OnGamemode, true);
		HookSingleEntityOutput(entity, "OnScavenge", OnGamemode, true);
		ActivateEntity(entity);
		AcceptEntityInput(entity, "PostSpawnActivate");
		if( IsValidEntity(entity) ) // Because sometimes "PostSpawnActivate" seems to kill the ent.
			RemoveEdict(entity); // Because multiple plugins creating at once, avoid too many duplicate ents in the same frame
	}

	if( g_iCurrentMode == 1 )
	{
		static char temp[8];
		g_hCvarMPGameMode.GetString(temp, sizeof(temp));
		if( strcmp(temp, "realism") == 0 )
		{
			g_iCurrentMode = 5;
		}
	}
}

void OnGamemode(const char[] output, int caller, int activator, float delay)
{
	if( strcmp(output, "OnCoop") == 0 )
		g_iCurrentMode = 1;
	else if( strcmp(output, "OnSurvival") == 0 )
		g_iCurrentMode = 2;
	else if( strcmp(output, "OnVersus") == 0 )
		g_iCurrentMode = 3;
	else if( strcmp(output, "OnScavenge") == 0 )
		g_iCurrentMode = 4;
}

void ConVarChanged_Cvars(Handle convar, const char[] oldValue, const char[] newValue)
{
	OnMapStart();
}

void ResetPlugin()
{
	g_bValidData = false;

	if( g_hSnap && g_hSnap.Length > 0 )
	{
		static char sMap[64];
		StringMap aMap;

		for( int i = 0; i < g_hSnap.Length; i++ )
		{
			g_hSnap.GetKey(i, sMap, sizeof(sMap));
			g_hData.GetValue(sMap, aMap);
			delete aMap;
		}
	}
	
	g_hData.Clear();
	delete g_hSnap;
}

void LoadConfig()
{
	static char sModel[PLATFORM_MAX_PATH];
	static char sPath[PLATFORM_MAX_PATH];
	static char sMap[64];
	StringMap aMap;



	// Clean data
	ResetPlugin();



	// Load config
	BuildPath(Path_SM, sPath, sizeof(sPath), CONFIG_DATA);
	if( FileExists(sPath) == false ) SetFailState("\n==========\nMissing required file: \"%s\".\nRead installation instructions again.\n==========", sPath);

	KeyValues hFile = new KeyValues("populations");
	if( !hFile.ImportFromFile(sPath) )
	{
		delete hFile;
		return;
	}



	// Check for current map in the config, or load from the "all" section
	GetCurrentMap(sMap, sizeof(sMap));

	if( hFile.JumpToKey(sMap) || hFile.JumpToKey("all") )
	{
		// Get the "file" path, by mode or default
		switch( g_iCurrentMode )
		{
			case 1:		hFile.GetString("coop", sPath, sizeof(sPath));
			case 2:		hFile.GetString("survival", sPath, sizeof(sPath));
			case 3:		hFile.GetString("versus", sPath, sizeof(sPath));
			case 4:		hFile.GetString("scavenge", sPath, sizeof(sPath));
			case 5:		hFile.GetString("realism", sPath, sizeof(sPath));
			default:	hFile.GetString("file", sPath, sizeof(sPath));
		}

		// Ignore no modes
		if( sPath[0] == 0 )
		{
			hFile.GetString("file", sPath, sizeof(sPath));
		}

		// Ignore blank configs
		if( sPath[0] == 0 )
		{
			delete hFile;
			return;
		}
		// Validate the config exists
		else if( !FileExists(sPath) )
		{
			LogError("Error: custom file \"%s\" missing.", sPath);
		}
		else
		{
			// Load population.txt keyvalues
			KeyValues hData = new KeyValues("Population");
			if( !hData.ImportFromFile(sPath) )
			{
				LogError("Failed to read the custom \"%s\" population config.", sPath);
			}
			else
			{
				#if DEBUG_PRINT
				PrintToServer(" ");
				PrintToServer("##### Population: Loading config [%s]", sPath);
				#endif

				char sTemp[64];
				int percent;
				int chance;
				bool passed;

				hData.GotoFirstSubKey(true);

				// Loop through the keyvalues "NavArea place names" sections
				do
				{
					hData.GetSectionName(sTemp, sizeof(sTemp));

					#if DEBUG_PRINT
					PrintToServer(" ");
					PrintToServer("##### Population: section [%s]", sTemp);
					#endif

					aMap = new StringMap();
					percent = 0;

					// Loop through the models and chance to spawn
					do
					{
						passed = true;
						hData.GotoFirstSubKey(false);
						hData.GetSectionName(sModel, sizeof(sModel));
						hData.GoBack();

						#if DEBUG_PRINT
						PrintToServer("##### Population: key [%s]", sModel);
						#endif

						// Ignore all models that are not "common" infected or Special Infected
						if( strncmp(sModel, "common", 6) && strcmp(sModel, "tank") && strcmp(sModel, "boomer") && strcmp(sModel, "hunter") && strcmp(sModel, "smoker") && strcmp(sModel, "charger") && strcmp(sModel, "jockey") && strcmp(sModel, "spitter") && strcmp(sModel, "boomette") )
						{
							passed = false;
							hData.JumpToKey(sModel);

							#if DEBUG_PRINT
							PrintToServer("##### Population: SKIP: INVALID MODEL [%s]", sModel);
							#endif
						}

						// Add together percentage
						chance = hData.GetNum(sModel);
						if( chance == 0 )
						{
							passed = false;
							#if DEBUG_PRINT
							PrintToServer("##### Population: SKIP: 0% CHANCE [%s]", sModel);
							#endif
						}

						hData.JumpToKey(sModel);

						if( passed )
						{
							percent += chance;

							#if DEBUG_PRINT
							PrintToServer("##### Population: val [%d]", percent);
							#endif

							// Set full model path
							if( strcmp(sModel, "tank") == 0 )
							{
								sModel = "hulk";
							}
							Format(sModel, sizeof(sModel), "models/infected/%s.mdl", sModel);

							// Config error checks
							if( percent > 100 )
							{
								LogError("\n==========\nError: percent adds up to > 100 (%d):\n===== File: \"%s\"\n===== Section: \"%s\"\n==========", percent, sPath, sTemp);
								ResetPlugin();
								return;
							}
							if( aMap.ContainsKey(sModel) )
							{
								LogError("\n==========\nError: duplicate model:\n===== File: \"%s\"\n===== Section: \"%s\"\n===== Model: \"%s\"\n==========", sPath, sTemp, sModel);
								ResetPlugin();
								return;
							}
							else if( FileExists(sModel, true) == false )
							{
								LogError("\n==========\nError: invalid model, file \"%s\" missing.\n==========", sModel);
								ResetPlugin();
								return;
							}
							// Save and Precache
							else
							{
								PrecacheModel(sModel);
								aMap.SetValue(sModel, percent);
							}
						}
					}
					while( hData.GotoNextKey(false) );

					// Error checking (0% can be from sections that do not have any common infected models)
					if( percent != 0 && percent != 100 )
					{
						LogError("\n==========\nError: percent does not add up to 100, (%d):\n===== File: \"%s\"\n===== Section: \"%s\"\n==========", percent, sPath, sTemp);
						ResetPlugin();
						return;
					}

					// Ready for next section
					hData.GoBack();

					// Save StringMap in global StringMap
					if( aMap.Size > 0 )
					{
						g_hData.SetValue(sTemp, aMap);
					}
					else
					{
						// Save a blank section to allow Special Infected to spawn
						delete aMap;
						g_hData.SetValue(sTemp, 0);
					}
				}
				while( hData.GotoNextKey(false) );



				// Rename config to force overriding
				if( FileExists("scripts/Kopulation.txt") )
					DeleteFile("scripts/Kopulation.txt");

				RenameFile("scripts/Kopulation.txt", sPath);

				// Patch config string name so it's loaded
				StoreToAddress(g_aPatchConfig, 'K', NumberType_Int8);

				// Reload population data
				// Note: Even though we call this to overwrite the config, common still spawn using the old config, hence why we continue to detour SelectModelByPopulation
				// Note: Although it seems to overwrite fine for InputspawnZombie, and hopefully other parts of the game using the population config
				Address director = L4D_GetPointer(POINTER_DIRECTOR);
				SDKCall(g_hSDK_ReloadPopulation, director);

				// Restore patched string
				StoreToAddress(g_aPatchConfig, 'p', NumberType_Int8);

				// Restore config name
				RenameFile(sPath, "scripts/Kopulation.txt");
			}
		}
	}

	if( g_hData.Size > 0 )
	{
		g_hSnap = g_hData.Snapshot();
		g_bValidData = true;
	}

	delete hFile;
}



// ====================================================================================================
// DETOURS
// ====================================================================================================
MRESReturn SelectModelByPopulation(DHookReturn hReturn, DHookParam hParams)
{
	if( !g_bValidData ) return MRES_Ignored;

	// Vars
	static char sPlace[64];
	StringMap aMap;

	// NavArea name
	DHookGetParamString(hParams, 1, sPlace, sizeof(sPlace));

	#if DEBUG_PRINT
	PrintToServer("##### Population: Entry [%s]", sPlace);
	#endif

	// Match "NavArea place names" or "default" section
	if( g_hData.GetValue(sPlace, aMap) || g_hData.GetValue("default", aMap) )
	{
		if( aMap ) // Ignore sections that have no data, Special Infected sections etc (if they trigger)
		{
			// Get model name and chance to spawn
			int size = aMap.Size;

			if( size > 0 )
			{
				// Vars
				int last = 101;
				int percent;
				int index = -1;
				int chance = GetRandomInt(1, 100);
				StringMapSnapshot aSnap = aMap.Snapshot();
				static char sModel[PLATFORM_MAX_PATH];

				// Loop models and chance
				for( int i = size - 1; i >= 0; i-- ) // This was supposed to order from 100 to 0 chance. But the "aSnap" is not ordered by index, so looping the whole list and using the "last" var to track the lowest valid percent
				{
					aSnap.GetKey(i, sModel, sizeof(sModel));
					aMap.GetValue(sModel, percent);

					// PrintToServer("##### LIST %d %d %s", i, percent, sModel);

					if( chance <= percent && percent < last )
					{
						index = i;
						last = percent;

						#if DEBUG_PRINT
						PrintToServer("##### Population: Index: %d Chance: %d/%d/%d [%s]", i, chance, percent, last, sModel);
						#endif
					}
				}

				// Override model
				if( index != -1 )
				{
					aSnap.GetKey(index, sModel, sizeof(sModel));
					delete aSnap;

					#if DEBUG_PRINT
					PrintToServer("##### Population: Selected [%s]", sModel);
					#endif

					hReturn.SetString(sModel);
					return MRES_Supercede;
				}
				#if DEBUG_PRINT
				else
				{
					PrintToServer("##### Selection failed: Chance %d/%d. Size: %d", chance, percent, size);
				}
				#endif

				delete aSnap;
			}
		}
	}

	return MRES_Ignored;
}

/*
// Uncommon infected trigger here when spawning
MRESReturn Infected_Spawn(int pThis, DHookReturn hReturn)
{
	int type = GetEntProp(pThis, Prop_Send, "m_Gender");

	switch( type )
	{
		case TYPE_CEDA:
		case TYPE_MUD_MEN:
		case TYPE_ROAD_WORKER:
		case TYPE_FALLEN:
		case TYPE_RIOT:
		case TYPE_CLOWN:
		case TYPE_JIMMY_GIBBS:
	}

	return MRES_Ignored;
}
*/