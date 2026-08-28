-- Grants DLC entitlements and mirrors every privilege across the locales the
-- client may request. GetPrivileges() filters on an EXACT locale match, so a
-- client asking for en-GB against an en-US-only table receives NOTHING -
-- including privilege 1, "Allow to play online".

-- Candidate IDs for the multiplayer DLC already installed on disk
-- (Da Vinci Disappearance maps + the three skin packs). IDs are inferred from
-- the existing 1000-1006 range and may need adjustment once the client is
-- observed calling GetPrivileges.
INSERT OR IGNORE INTO privileges VALUES
  (1002, 'Alhambra Map',        'en-US'),
  (1003, 'Mont Saint-Michel Map','en-US'),
  (1007, 'Pienza Map',          'en-US'),
  (1008, 'DLC Skin Pack 1',     'en-US'),
  (1009, 'DLC Skin Pack 2',     'en-US'),
  (1010, 'DLC Skin Pack 3',     'en-US');

-- Mirror the full en-US set into other locales.
INSERT OR IGNORE INTO privileges (id, description, locale)
SELECT id, description, l.code
FROM privileges p
CROSS JOIN (SELECT 'en-GB' AS code UNION SELECT 'en' UNION SELECT 'en-AU'
            UNION SELECT 'en-CA' UNION SELECT 'fr-FR' UNION SELECT 'de-DE'
            UNION SELECT 'es-ES' UNION SELECT 'it-IT') l
WHERE p.locale = 'en-US';
