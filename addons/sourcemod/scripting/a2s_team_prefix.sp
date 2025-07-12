#pragma newdecls required
#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <dhooks>


public Plugin myinfo =
{
  name        = "[A2S_PLAYER] TeamPrefix",
  author      = "Poggu, TouchMe",
  description = "Add team tags in A2S_PLAYER response",
  version     = "build_0001"
};


#define GAMEDATA_FILE "a2s_team_prefix.games"

/**
 * Teams.
 */
#define TEAM_SPECTATOR          1
#define TEAM_SURVIVOR           2
#define TEAM_INFECTED           3

#define CACHE_TTL               3.0

#define MAXSIZE_DATA            2048


// NET_SendPacket(netchan, socket, address, data, length)
enum
{
    ARG_Netchan = 1,  
    ARG_Socket,     
    ARG_Address,     
    ARG_Data,       
    ARG_Length
};

int A2S_PLAYER[] = { 0xFF, 0xFF, 0xFF, 0xFF, 0x44 };


public void OnPluginStart()
{
    GameData hGameConf = LoadGameConfigFile(GAMEDATA_FILE);
    if(!hGameConf) {
        SetFailState("Missing gamedata \"" ... GAMEDATA_FILE ... "\"");
    }

    Handle hNetSendPacket = null;
    Address addrSendPacket = hGameConf.GetMemSig("NET_SendPacket");
    if (addrSendPacket == Address_Null)
    {
        SetFailState("NET_SendPacket: signature not found in engine.[dll|so] (no match for pattern from gamedata).");
    }
    else
    {
        hNetSendPacket = DHookCreateDetour(addrSendPacket, CallConv_CDECL, ReturnType_Int, ThisPointer_Ignore);

        if (!hNetSendPacket) {
            SetFailState("DHookCreateDetour: Failed to create detour for NET_SendPacket.");
        }

        if (!DHookSetFromConf(hNetSendPacket, hGameConf, SDKConf_Signature, "NET_SendPacket")) {
            SetFailState("DHookSetFromConf: Failed signature exists, but detour setup may be incompatible (e.g. incorrect prototype or calling convention).");
        }
    }

    if (hGameConf.GetOffset("WindowsOrLinux") == 1)
    {
        DHookAddParam(hNetSendPacket, HookParamType_Int, .custom_register=DHookRegister_ECX);
        DHookAddParam(hNetSendPacket, HookParamType_ObjectPtr, -1, .custom_register=DHookRegister_EDX); // Windows call convention
        DHookAddParam(hNetSendPacket, HookParamType_Int);
        DHookAddParam(hNetSendPacket, HookParamType_Int);
        DHookAddParam(hNetSendPacket, HookParamType_Int);
    }
    else
    {
        DHookAddParam(hNetSendPacket, HookParamType_Int);
        DHookAddParam(hNetSendPacket, HookParamType_Int);
        DHookAddParam(hNetSendPacket, HookParamType_Int);
        DHookAddParam(hNetSendPacket, HookParamType_Int);
        DHookAddParam(hNetSendPacket, HookParamType_Int);
    }

    if (!DHookEnableDetour(hNetSendPacket, false, Detour_OnNetSendPacket)) {
        SetFailState("Failed to detour NET_SendPacket.");
    }

    delete hGameConf;
}

public MRESReturn Detour_OnNetSendPacket(Handle hReturn, Handle hParams)
{
    static char szCachedResponse[MAXSIZE_DATA];
    static int iCachedLength;
    static float fLastBuildTime;

    Address adressPacketData = DHookGetParam(hParams, ARG_Data);
    int iPacketLength = DHookGetParam(hParams, ARG_Length);

    if (iPacketLength < sizeof(A2S_PLAYER)) {
        return MRES_Ignored;
    }

    if (!IsA2SPlayerRequest(adressPacketData)) {
        return MRES_Ignored;
    }

    float fCurrentTime = GetEngineTime();

    if (fCurrentTime - fLastBuildTime > CACHE_TTL)
    {
        iCachedLength = BuildResponse(szCachedResponse);
        fLastBuildTime = fCurrentTime;
    }
    
    for(int i = 0; i < iCachedLength; i++)
    {
        StoreToAddress(adressPacketData + view_as<Address>(i), szCachedResponse[i], NumberType_Int8);
    }

    DHookSetParam(hParams, ARG_Length, iCachedLength);

    return MRES_ChangedHandled;
}

bool IsA2SPlayerRequest(Address address)
{
    for (int i = 0; i < sizeof(A2S_PLAYER); i++)
    {
        if (A2S_PLAYER[i] != LoadFromAddress(address + view_as<Address>(i), NumberType_Int8)) {
            return false;
        }
    }
    return true;
}

int BuildResponse(char[] szOut)
{
    int iPos = 0;

    BuildResponseHeader(szOut, iPos);

    int iCountOffset = iPos++;

    szOut[iCountOffset] = BuildResponsePlayers(szOut, iPos);

    return iPos;
}

void BuildResponseHeader(char[] szOut, int &iPos)
{
    for (int i = 0; i < sizeof(A2S_PLAYER); i++)
    {
        szOut[iPos++] = A2S_PLAYER[i];
    }
}

int BuildResponsePlayers(char[] szOut, int &iPos)
{
    int iPlayerCount = 0;

    char szName[MAX_NAME_LENGTH];
    for (int iPlayer = 1; iPlayer <= MaxClients; iPlayer ++)
    {
        if (!IsClientInGame(iPlayer) || IsFakeClient(iPlayer)) {
            continue;
        }

        switch (GetClientTeam(iPlayer))
        {
            case TEAM_INFECTED: FormatEx(szName, sizeof(szName), "[SI] %N", iPlayer);
            case TEAM_SURVIVOR: FormatEx(szName, sizeof(szName), "[S] %N", iPlayer);
            case TEAM_SPECTATOR: FormatEx(szName, sizeof(szName), "[SPEC] %N", iPlayer);
            default: FormatEx(szName, sizeof(szName), "[?] %N", iPlayer);
        }

        BuildResponsePlayer(szOut, iPos, iPlayerCount++, szName, GetClientFrags(iPlayer), GetClientTime(iPlayer));
    }

    return iPlayerCount;
}

void BuildResponsePlayer(char[] szOut, int &iPos, int iIndex, char[] szName, int iFrags, float fTime)
{
    // Index
    szOut[iPos++] = iIndex;

    // Name
    int len = strlen(szName);
    for (int j = 0; j < len; j++)
    szOut[iPos++] = szName[j];
    szOut[iPos++] = 0x00; // null terminator

    // Score
    szOut[iPos++] = iFrags & 0xFF;
    szOut[iPos++] = (iFrags >> 8) & 0xFF;
    szOut[iPos++] = (iFrags >> 16) & 0xFF;
    szOut[iPos++] = (iFrags >> 24) & 0xFF;

    // Time
    int iTime = view_as<int>(fTime);
    szOut[iPos++] = iTime & 0xFF;
    szOut[iPos++] = (iTime >> 8) & 0xFF;
    szOut[iPos++] = (iTime >> 16) & 0xFF;
    szOut[iPos++] = (iTime >> 24) & 0xFF;
}
