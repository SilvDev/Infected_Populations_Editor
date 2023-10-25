/*
*	Infected Populations Editor
*	Copyright (C) 2023 Silvers
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



#define PLUGIN_VERSION		"1.0"

/*======================================================================================
	Plugin Info:

*	Name	:	[L4D2] Infected Populations Editor
*	Author	:	SilverShot
*	Descrp	:	Modify population.txt values by config instead of conflicting VPK files.
*	Link	:	https://forums.alliedmods.net/showthread.php?t=344298
*	Plugins	:	https://sourcemod.net/plugins.php?exact=exact&sortby=title&search=1&author=Silvers

========================================================================================
	Change Log:

1.0 (25-Oct-2023)
	- Initial release.

======================================================================================*/

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <dhooks>


#define CVAR_FLAGS			FCVAR_NOTIFY
#define GAMEDATA			"l4d_population_editor"
#define CONFIG_DATA			"data/l4d_population_editor.cfg"
#define DEBUG_PRINT			0 // Debug print the models loaded, the chance etc


bool g_bValidData;
StringMap g_hData;
StringMapSnapshot g_hSnap;



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

	Handle hGameData = LoadGameConfigFile(GAMEDATA);
	if( hGameData == null ) SetFailState("Failed to load \"%s.txt\" gamedata.", GAMEDATA);



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
	LoadConfig();
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
		// Get the "file" path
		hFile.GetString("file", sPath, sizeof(sPath));

		// Validate the config exists
		if( !FileExists(sPath) )
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
				char sTemp[64];
				int percent;

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
						hData.GotoFirstSubKey(false);
						hData.GetSectionName(sModel, sizeof(sModel));
						hData.GoBack();

						#if DEBUG_PRINT
						PrintToServer("##### Population: key [%s]", sModel);
						#endif

						// Ignore all models that are not "common" infected
						if( strncmp(sModel, "common", 6) )
						{
							hData.JumpToKey(sModel);
							continue;
						}

						// Add together percentage
						percent += hData.GetNum(sModel);
						hData.JumpToKey(sModel);

						#if DEBUG_PRINT
						PrintToServer("##### Population: val [%d]", percent);
						#endif

						// Set full model path
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

					// Save snapshot in StringMap
					if( aMap.Size > 0 )
					{
						g_hData.SetValue(sTemp, aMap);
					}
				}
				while( hData.GotoNextKey(false) );
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
	PrintToServer("##### Population: entry [%s]", sPlace);
	#endif

	// Match "NavArea place names" or "default" section
	if( g_hData.GetValue(sPlace, aMap) || g_hData.GetValue("default", aMap) )
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

	return MRES_Ignored;
}

/*
MRESReturn Infected_Spawn(int pThis, DHookReturn hReturn)
{
	return MRES_Ignored;
}
*/