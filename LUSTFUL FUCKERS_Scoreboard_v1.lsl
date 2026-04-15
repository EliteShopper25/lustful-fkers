// ═══════════════════════════════════════════════════════════════════
// LOAD CHALLENGE v2 — DIGITAL SCOREBOARD (Media-on-a-Prim + Local Shout)
// ═══════════════════════════════════════════════════════════════════
//
// Displays a LIVE webpage on the prim face using llSetPrimMediaOnFace.
// The webpage cycles Top 10 → Top 5 → Top 3 every 45 seconds.
// NO hover text — digital display on board + shout to local chat each cycle.
//
// HOW IT WORKS:
//   1. Script listens for SCORE messages from chairs on SCORE_CHANNEL
//   2. Stores all player data in-memory
//   3. Periodically refreshes the media URL with latest scores
//   4. The webpage renders the scoreboard visually
//   5. Every cycle phase change, the current standings are shouted in local chat
//
// SCORE MESSAGE FORMAT (from chairs):
//   "SCORE|<uuid>|<total_points>|<display_name>|<partner_count>"
//
// SETUP:
//   1. Set SCOREBOARD_URL below to your deployed webpage URL
//   2. Drop this script into any rezzed prim in the sim
//   3. The prim face (front) will display the scoreboard webpage
//   4. No other configuration needed
//
// NOTE: The prim must have media enabled. This script auto-sets it.
//       Viewers need "Media on prims" enabled in Preferences → Sound & Media.
// ═══════════════════════════════════════════════════════════════════

// ╔══════════════════════════════════════════╗
// ║  CHANGE THIS TO YOUR DEPLOYED PAGE URL  ║
// ╚══════════════════════════════════════════╝
string SCOREBOARD_URL = "PASTE_YOUR_URL_HERE";

integer SCORE_CHANNEL  = -77802;
integer MAX_PLAYERS    = 50;
integer MEDIA_FACE     = 0;     // Which prim face shows the webpage (0 = front)
integer REFRESH_SECS   = 10;    // How often to push updated scores to the webpage
integer SHOUT_INTERVAL = 45;    // How often to shout standings in local (matches webpage cycle)
integer shoutTimer     = 0;
integer shoutPhase     = 0;     // 0=Top10, 1=Top5, 2=Top3

// ──── STORAGE ────
list playerKeys        = [];
list playerNames       = [];
list playerScores      = [];
list playerPartners    = [];
list playerGallonsMark = []; // highest whole-gallon milestone already shouted per player

integer refreshTimer = 0;
integer dirty        = FALSE;   // TRUE when scores changed since last push

// ──── FIND / UPSERT ────
integer FindPlayer(string uid) {
    return llListFindList(playerKeys, [uid]);
}

UpsertPlayer(key id, integer score, string dname, integer partners) {
    string skey = (string)id;
    if (dname == "" || dname == "???") dname = llKey2Name(id);

    integer idx = FindPlayer(skey);
    if (idx == -1) {
        if (llGetListLength(playerKeys) >= MAX_PLAYERS) {
            integer minScore = llList2Integer(playerScores, 0);
            integer minIdx   = 0;
            integer j;
            for (j = 1; j < llGetListLength(playerScores); j++) {
                if (llList2Integer(playerScores, j) < minScore) {
                    minScore = llList2Integer(playerScores, j);
                    minIdx   = j;
                }
            }
            if (score <= minScore) return;
            playerKeys        = llListReplaceList(playerKeys,        [skey],        minIdx, minIdx);
            playerNames       = llListReplaceList(playerNames,       [dname],       minIdx, minIdx);
            playerScores      = llListReplaceList(playerScores,      [score],       minIdx, minIdx);
            playerPartners    = llListReplaceList(playerPartners,    [partners],    minIdx, minIdx);
            playerGallonsMark = llListReplaceList(playerGallonsMark, [score / 128], minIdx, minIdx);
            idx = minIdx;
        } else {
            playerKeys        += [skey];
            playerNames       += [dname];
            playerScores      += [score];
            playerPartners    += [partners];
            playerGallonsMark += [score / 128]; // seed to current so we don't re-shout old milestones
            idx = llGetListLength(playerKeys) - 1;
        }
    } else {
        playerNames    = llListReplaceList(playerNames,    [dname],    idx, idx);
        playerScores   = llListReplaceList(playerScores,   [score],    idx, idx);
        playerPartners = llListReplaceList(playerPartners, [partners], idx, idx);
    }
    dirty = TRUE;
    CheckGallonMilestone(idx, dname, score);
}

// ──── SORT (returns sorted index list, descending by score) ────
list GetSortedIndices() {
    integer total = llGetListLength(playerKeys);
    list pairs = [];
    integer i;
    for (i = 0; i < total; i++) {
        integer invScore = 9999999 - llList2Integer(playerScores, i);
        pairs += [invScore, i];
    }
    pairs = llListSort(pairs, 2, TRUE);

    list indices = [];
    for (i = 0; i < llGetListLength(pairs); i += 2) {
        indices += [llList2Integer(pairs, i + 1)];
    }
    return indices;
}

// ──── BUILD SCORE URL ────
// Appends player data as URL parameters so the webpage can read them.
// Format: ?d=name~pts~partners,name~pts~partners,...
// Limited to top 10 to fit in URL length limits.
string BuildScoreURL() {
    list sorted = GetSortedIndices();
    integer count = llGetListLength(sorted);
    if (count > 10) count = 10;

    string data = "";
    integer i;
    for (i = 0; i < count; i++) {
        integer idx  = llList2Integer(sorted, i);
        string  n    = llList2String(playerNames, idx);
        integer pts  = llList2Integer(playerScores, idx);
        integer part = llList2Integer(playerPartners, idx);

        // URL-safe: replace spaces with +
        n = llDumpList2String(llParseString2List(n, [" "], []), "+");

        if (i > 0) data += ",";
        data += n + "~" + (string)pts + "~" + (string)part;
    }

    if (data == "") return SCOREBOARD_URL;
    return SCOREBOARD_URL + "?d=" + data + "&t=" + (string)llGetUnixTime();
}

// ──── SET MEDIA ON PRIM FACE ────
SetMedia(string url) {
    // Clear any existing media first
    llClearPrimMedia(MEDIA_FACE);

    // Set the webpage on the prim face
    llSetPrimMediaParams(MEDIA_FACE, [
        PRIM_MEDIA_AUTO_PLAY,   TRUE,
        PRIM_MEDIA_CURRENT_URL, url,
        PRIM_MEDIA_HOME_URL,    url,
        PRIM_MEDIA_AUTO_SCALE,  TRUE,
        PRIM_MEDIA_AUTO_ZOOM,   FALSE,
        PRIM_MEDIA_PERMS_INTERACT, PRIM_MEDIA_PERM_NONE, // No user interaction needed
        PRIM_MEDIA_WIDTH_PIXELS,  512,
        PRIM_MEDIA_HEIGHT_PIXELS, 512
    ]);
}

// ──── GALLON MILESTONE SHOUT ────
// Fires a sim-wide shout the first time a player crosses each whole-gallon threshold.
// Called every time UpsertPlayer receives an updated score.
CheckGallonMilestone(integer idx, string playerName, integer pts) {
    integer gallons = pts / 128;
    integer prevMark = llList2Integer(playerGallonsMark, idx);
    if (gallons > prevMark && gallons > 0) {
        playerGallonsMark = llListReplaceList(playerGallonsMark, [gallons], idx, idx);
        string trophy;
        if      (gallons >= 100) trophy = "🏆💦";
        else if (gallons >= 50)  trophy = "🏆";
        else if (gallons >= 25)  trophy = "👑";
        else if (gallons >= 10)  trophy = "🌊";
        else if (gallons >= 5)   trophy = "💦";
        else                     trophy = "💧";
        string plural = "s";
        if (gallons == 1) plural = "";
        llShout(0,
            trophy + " GALLON MILESTONE! " + trophy + "\n" +
            playerName + " just hit " + (string)gallons +
            " gallon" + plural + " of cum! 🍆\n" +
            "Total Score: " + (string)pts + " pts"
        );
    }
}

// ──── TRUNCATE NAME ────
string TruncName(string n, integer maxLen) {
    if (llStringLength(n) > maxLen) return llGetSubString(n, 0, maxLen - 2) + "…";
    return n;
}

// ──── GALLONS CONVERSION ────
// 128 pts = 1 gallon
string ToGallons(integer pts) {
    float g = (float)pts / 128.0;
    if (g < 0.01) return "<0.01 gal";
    if (g >= 100.0) return (string)((integer)g) + " gal";
    if (g >= 10.0) {
        integer whole = (integer)g;
        integer dec   = (integer)((g - (float)whole) * 10.0);
        return (string)whole + "." + (string)dec + " gal";
    }
    integer whole = (integer)g;
    integer dec   = (integer)((g - (float)whole) * 100.0);
    string decStr = (string)dec;
    if (dec < 10) decStr = "0" + decStr;
    return (string)whole + "." + decStr + " gal";
}

// ──── BUILD SHOUT TEXT ────
string BuildTop10Shout(list sorted) {
    integer count = llGetListLength(sorted);
    integer shown = count; if (shown > 10) shown = 10;
    list medals = ["🥇","🥈","🥉"];
    string out = "⚔ ═══ LUSTFUL FUCKERS — TOP 10 ═══ ⚔\n";
    integer i;
    for (i = 0; i < shown; i++) {
        integer idx  = llList2Integer(sorted, i);
        string  n    = TruncName(llList2String(playerNames, idx), 20);
        integer pts  = llList2Integer(playerScores, idx);
        integer part = llList2Integer(playerPartners, idx);
        string prefix;
        if (i < 3) prefix = llList2String(medals, i);
        else        prefix = "  " + (string)(i+1) + ".";
        out += prefix + " " + n + "  " + (string)pts + " pts | " + ToGallons(pts) + " | 💞 " + (string)part + "\n";
    }
    if (count == 0) out += "  No players yet!\n";
    out += "⚔ ══════════════════════════════ ⚔";
    return out;
}

string BuildTop5Shout(list sorted) {
    integer count = llGetListLength(sorted);
    integer shown = count; if (shown > 5) shown = 5;
    list medals = ["🥇","🥈","🥉"," 4."," 5."];
    string out = "💋 ═══ LUSTFUL FUCKERS — TOP 5 ═══ 💋\n";
    integer i;
    for (i = 0; i < shown; i++) {
        integer idx  = llList2Integer(sorted, i);
        string  n    = TruncName(llList2String(playerNames, idx), 22);
        integer pts  = llList2Integer(playerScores, idx);
        integer part = llList2Integer(playerPartners, idx);
        out += llList2String(medals, i) + " " + n + "  " + (string)pts + " pts | " + ToGallons(pts) + " | 💞 " + (string)part + "\n";
    }
    if (count == 0) out += "  No players yet!\n";
    out += "💋 ══════════════════════════════ 💋";
    return out;
}

string BuildTop3Shout(list sorted) {
    integer count = llGetListLength(sorted);
    integer shown = count; if (shown > 3) shown = 3;
    list labels = ["🥇 1ST PLACE","🥈 2ND PLACE","🥉 3RD PLACE"];
    string out = "👑 ════ LUSTFUL FUCKERS CHAMPIONS ════ 👑\n";
    integer i;
    for (i = 0; i < shown; i++) {
        integer idx  = llList2Integer(sorted, i);
        string  n    = TruncName(llList2String(playerNames, idx), 24);
        integer pts  = llList2Integer(playerScores, idx);
        integer part = llList2Integer(playerPartners, idx);
        out += llList2String(labels, i) + ": " + n + "\n";
        out += "       " + (string)pts + " pts  |  " + ToGallons(pts) + "  |  💞 " + (string)part + " shared\n";
    }
    if (count == 0) out += "  No champions yet!\n";
    out += "👑 ══════════════════════════════ 👑";
    return out;
}

// ──── SHOUT CURRENT PHASE ────
ShoutPhase() {
    list sorted = GetSortedIndices();
    string msg;
    if      (shoutPhase == 0) msg = BuildTop10Shout(sorted);
    else if (shoutPhase == 1) msg = BuildTop5Shout(sorted);
    else                      msg = BuildTop3Shout(sorted);
    llShout(0, msg);
    shoutPhase = (shoutPhase + 1) % 3;
}

// ──── PUSH SCORES TO DISPLAY ────
PushScores() {
    string url = BuildScoreURL();
    SetMedia(url);
    dirty = FALSE;
}

// ──── DEFAULT STATE ────
default {
    state_entry() {
        llListen(SCORE_CHANNEL, "", "", "");
        llSetTimerEvent(1.0);
        llSetText("", ZERO_VECTOR, 0.0);  // NO hover text

        // Initialize media face
        if (SCOREBOARD_URL != "PASTE_YOUR_URL_HERE") {
            SetMedia(SCOREBOARD_URL);
            llOwnerSay("⚔ Lustful Fuckers Digital Scoreboard active. Displaying: " + SCOREBOARD_URL);
        } else {
            llOwnerSay("⚔ Scoreboard: Set SCOREBOARD_URL in the script to your deployed page URL, then reset.");
        }

        refreshTimer = REFRESH_SECS;
        shoutTimer   = SHOUT_INTERVAL;
        shoutPhase   = 0;
    }

    listen(integer channel, string name, key id, string msg) {
        if (channel != SCORE_CHANNEL) return;

        // Format: "SCORE|<uuid>|<points>|<display_name>|<partner_count>"
        list parts = llParseString2List(msg, ["|"], []);
        if (llGetListLength(parts) >= 5 && llList2String(parts, 0) == "SCORE") {
            key     aKey     = (key)llList2String(parts, 1);
            integer score    = (integer)llList2String(parts, 2);
            string  dname    = llList2String(parts, 3);
            integer partners = (integer)llList2String(parts, 4);
            UpsertPlayer(aKey, score, dname, partners);
        }
    }

    timer() {
        // Media refresh
        refreshTimer--;
        if (refreshTimer <= 0) {
            refreshTimer = REFRESH_SECS;
            if (dirty || llGetListLength(playerKeys) > 0) {
                PushScores();
            }
        }

        // Local shout cycle
        shoutTimer--;
        if (shoutTimer <= 0) {
            shoutTimer = SHOUT_INTERVAL;
            if (llGetListLength(playerKeys) > 0) {
                ShoutPhase();
            }
        }
    }

    touch_start(integer num) {
        if (llDetectedKey(0) == llGetOwner()) {
            // Manual refresh + immediate shout
            PushScores();
            ShoutPhase();
            llOwnerSay("Scoreboard: manual refresh + shout triggered.");
        }
    }

    on_rez(integer param) {
        llResetScript();
    }
}
