-- The help messages that tell a player what to do, in their language. Language: "language = xx" in
-- mirror_settings.txt, else the Windows display language (the bridge's lobby file), else English.
-- Logs stay English. Only languages the game's font (RU_EN) can show are listed.

local i18n = {}

local T = {
    en = {
        stray_title = "LEFTOVER CO-OP SAVE",
        stray_msg = "This is a leftover co-op save, not your own world. LOAD MY SAVE loads your own save %s - then you can join or host.",
        stray_ok = "LOAD MY SAVE",
        stray_none = "This is a leftover co-op save, not your own world. Load one of your own saves from the main menu.",
        session_unfinished = "Your last co-op session hasn't finished yet. Restart the game to complete it, then join.",
        session_rescued = "Your last co-op session couldn't be finished. Your own save is as it was before you joined, and your co-op character is kept in Backups (J, CO-OP tab, BACKUPS). You can join again.",
        session_closed = "Your last co-op session couldn't be finished. Your own save is as it was before you joined. You can join again.",
        no_host = "No host is connected yet. Your friend needs to be in-game with SurrounSync and choose Host.",
        backup_failed = "Couldn't back up your save, so you can't join. Check that your disk has free space and the game can write to its save folder.",
        path_broken = "SurrounSync can't reach your save folder (your Windows user name has letters it can't use). Close the game, run SurrounSync Setup and click FIX.",
        disk_full = "Your disk is full, so your save couldn't be backed up and you can't join. Free some space and try again.",
        files_blocked = "Windows blocked SurrounSync from writing your save backup (antivirus or read-only files?). Run SurrounSync Setup and click FIX, or allow the game in your antivirus.",
        cant_save_here = "Your game couldn't be saved here, so you can't join yet. Move to a spot where saving works and try again.",
        cant_identify = "Couldn't identify your current save, so you can't join. Please send a bug report.",
        load_own_first = "Load one of your own saves first, then join.",
        peer_older = "%s has an older SurrounSync. They need to update with SurrounSync Setup, then you both restart the game.",
        me_older = "Your SurrounSync is older than %s's. Update with SurrounSync Setup, then restart the game.",
        version_differs = "You and %s have different SurrounSync versions. Both update with SurrounSync Setup, then restart the game.",
        game_build = "You and %s have different SurrounDead game versions. Both update the game in Steam, then restart it.",
        update_title = "SURROUNSYNC %s IS OUT",
        update_msg = "A new SurrounSync version is ready. ACCEPT opens the updater - it installs the update as soon as you close the game. Both players need the same version to play together.",
        update_ok = "ACCEPT",
    },
    ru = {
        stray_title = "СТАРОЕ СОХРАНЕНИЕ КООПЕРАТИВА",
        stray_msg = "Это старое сохранение кооператива, а не ваш мир. «ЗАГРУЗИТЬ МОЁ» загрузит ваше сохранение %s - после этого можно присоединиться или стать хостом.",
        stray_ok = "ЗАГРУЗИТЬ МОЁ",
        stray_none = "Это старое сохранение кооператива, а не ваш мир. Загрузите своё сохранение в главном меню.",
        session_unfinished = "Прошлая кооп-сессия ещё не завершена. Перезапустите игру, чтобы её завершить, затем присоединяйтесь.",
        session_rescued = "Последнюю совместную сессию не удалось завершить. Ваше сохранение осталось таким, каким было до входа, а персонаж из совместной игры сохранён в резервных копиях (J, вкладка CO-OP, BACKUPS). Можно снова присоединяться.",
        session_closed = "Последнюю совместную сессию не удалось завершить. Ваше сохранение осталось таким, каким было до входа. Можно снова присоединяться.",
        no_host = "Хост ещё не подключён. Ваш друг должен быть в игре с SurrounSync и выбрать HOST.",
        backup_failed = "Не удалось сделать резервную копию сохранения, поэтому присоединиться нельзя. Проверьте свободное место на диске и доступ игры к папке сохранений.",
        path_broken = "SurrounSync не может открыть папку сохранений (в имени пользователя Windows есть буквы, которые он не может использовать). Закройте игру, запустите SurrounSync Setup и нажмите FIX.",
        disk_full = "Диск заполнен, поэтому сохранение не удалось скопировать, и присоединиться нельзя. Освободите место и попробуйте снова.",
        files_blocked = "Windows не дала SurrounSync записать резервную копию (антивирус или файлы только для чтения?). Запустите SurrounSync Setup и нажмите FIX или разрешите игру в антивирусе.",
        cant_save_here = "Игру здесь не удалось сохранить, поэтому присоединиться пока нельзя. Перейдите туда, где сохранение работает, и попробуйте снова.",
        cant_identify = "Не удалось определить ваше текущее сохранение, поэтому присоединиться нельзя. Отправьте отчёт об ошибке.",
        load_own_first = "Сначала загрузите одно из своих сохранений, затем присоединяйтесь.",
        peer_older = "У %s старая версия SurrounSync. Нужно обновить её через SurrounSync Setup, затем перезапустите игру оба.",
        me_older = "Ваша версия SurrounSync старее, чем у %s. Обновите её через SurrounSync Setup и перезапустите игру.",
        version_differs = "У вас и у %s разные версии SurrounSync. Обновитесь оба через SurrounSync Setup и перезапустите игру.",
        game_build = "У вас и у %s разные версии игры SurrounDead. Обновите игру в Steam оба и перезапустите её.",
        update_title = "ВЫШЛА SURROUNSYNC %s",
        update_msg = "Готова новая версия SurrounSync. «ПРИНЯТЬ» откроет программу обновления - она установит обновление, как только вы закроете игру. Чтобы играть вместе, у обоих должна быть одна версия.",
        update_ok = "ПРИНЯТЬ",
    },
    de = {
        stray_title = "ÜBRIGER KOOP-SPIELSTAND",
        stray_msg = "Das ist ein übrig gebliebener Koop-Spielstand, nicht deine Welt. MEIN SPIEL LADEN lädt deinen Spielstand %s - danach kannst du beitreten oder hosten.",
        stray_ok = "MEIN SPIEL LADEN",
        stray_none = "Das ist ein übrig gebliebener Koop-Spielstand, nicht deine Welt. Lade im Hauptmenü einen deiner eigenen Spielstände.",
        session_unfinished = "Deine letzte Koop-Sitzung ist noch nicht abgeschlossen. Starte das Spiel neu, um sie abzuschließen, und tritt dann bei.",
        session_rescued = "Deine letzte Koop-Sitzung konnte nicht abgeschlossen werden. Dein Spielstand ist so wie vor dem Beitreten, und deine Koop-Figur liegt in den Sicherungen (J, Reiter CO-OP, BACKUPS). Du kannst wieder beitreten.",
        session_closed = "Deine letzte Koop-Sitzung konnte nicht abgeschlossen werden. Dein Spielstand ist so wie vor dem Beitreten. Du kannst wieder beitreten.",
        no_host = "Noch kein Host verbunden. Dein Freund muss mit SurrounSync im Spiel sein und HOST wählen.",
        backup_failed = "Dein Spielstand konnte nicht gesichert werden, deshalb kannst du nicht beitreten. Prüfe den freien Speicherplatz und ob das Spiel in seinen Speicherordner schreiben darf.",
        path_broken = "SurrounSync erreicht deinen Speicherordner nicht (dein Windows-Benutzername enthält Zeichen, die es nicht verwenden kann). Schließe das Spiel, starte SurrounSync Setup und klicke auf FIX.",
        disk_full = "Deine Festplatte ist voll, deshalb konnte dein Spielstand nicht gesichert werden und du kannst nicht beitreten. Schaffe Platz und versuche es erneut.",
        files_blocked = "Windows hat SurrounSync das Schreiben der Sicherung verweigert (Antivirus oder schreibgeschützte Dateien?). Starte SurrounSync Setup und klicke auf FIX oder erlaube das Spiel in deinem Antivirus.",
        cant_save_here = "Dein Spiel konnte hier nicht speichern, deshalb kannst du noch nicht beitreten. Geh an eine Stelle, an der Speichern funktioniert, und versuche es erneut.",
        cant_identify = "Dein aktueller Spielstand wurde nicht erkannt, deshalb kannst du nicht beitreten. Bitte sende einen Fehlerbericht.",
        load_own_first = "Lade zuerst einen deiner eigenen Spielstände, dann tritt bei.",
        peer_older = "%s nutzt eine ältere SurrounSync-Version. Bitte über SurrounSync Setup aktualisieren, danach startet ihr beide das Spiel neu.",
        me_older = "Deine SurrounSync-Version ist älter als die von %s. Aktualisiere sie mit SurrounSync Setup und starte das Spiel neu.",
        version_differs = "Du und %s habt verschiedene SurrounSync-Versionen. Aktualisiert beide mit SurrounSync Setup und startet das Spiel neu.",
        game_build = "Du und %s habt verschiedene SurrounDead-Versionen. Aktualisiert beide das Spiel in Steam und startet es neu.",
        update_title = "SURROUNSYNC %s IST DA",
        update_msg = "Eine neue SurrounSync-Version ist bereit. AKZEPTIEREN öffnet das Update-Programm - es installiert das Update, sobald du das Spiel schließt. Zum gemeinsamen Spielen braucht ihr beide dieselbe Version.",
        update_ok = "AKZEPTIEREN",
    },
    es = {
        stray_title = "PARTIDA COOP SOBRANTE",
        stray_msg = "Esta es una partida cooperativa sobrante, no tu mundo. CARGAR LA MÍA carga tu partida %s; después puedes unirte o ser anfitrión.",
        stray_ok = "CARGAR LA MÍA",
        stray_none = "Esta es una partida cooperativa sobrante, no tu mundo. Carga una de tus partidas desde el menú principal.",
        session_unfinished = "Tu última sesión cooperativa aún no ha terminado. Reinicia el juego para completarla y luego únete.",
        session_rescued = "Tu última sesión cooperativa no se pudo terminar. Tu partida está como antes de unirte y tu personaje cooperativo se guarda en las copias de seguridad (J, pestaña CO-OP, BACKUPS). Ya puedes volver a unirte.",
        session_closed = "Tu última sesión cooperativa no se pudo terminar. Tu partida está como antes de unirte. Ya puedes volver a unirte.",
        no_host = "Todavía no hay ningún anfitrión conectado. Tu amigo debe estar en el juego con SurrounSync y elegir HOST.",
        backup_failed = "No se pudo hacer una copia de seguridad de tu partida, así que no puedes unirte. Comprueba el espacio libre en disco y que el juego pueda escribir en su carpeta de partidas.",
        path_broken = "SurrounSync no puede acceder a tu carpeta de partidas (tu nombre de usuario de Windows tiene letras que no puede usar). Cierra el juego, abre SurrounSync Setup y pulsa FIX.",
        disk_full = "Tu disco está lleno, así que no se pudo hacer la copia de tu partida y no puedes unirte. Libera espacio y vuelve a intentarlo.",
        files_blocked = "Windows impidió que SurrounSync guardara la copia de seguridad (¿antivirus o archivos de solo lectura?). Abre SurrounSync Setup y pulsa FIX, o permite el juego en tu antivirus.",
        cant_save_here = "Tu juego no pudo guardar aquí, así que aún no puedes unirte. Ve a un lugar donde se pueda guardar e inténtalo de nuevo.",
        cant_identify = "No se pudo identificar tu partida actual, así que no puedes unirte. Envía un informe de error.",
        load_own_first = "Primero carga una de tus partidas y luego únete.",
        peer_older = "%s tiene una versión antigua de SurrounSync. Debe actualizarla con SurrounSync Setup; después, reiniciad los dos el juego.",
        me_older = "Tu versión de SurrounSync es más antigua que la de %s. Actualízala con SurrounSync Setup y reinicia el juego.",
        version_differs = "Tú y %s tenéis versiones distintas de SurrounSync. Actualizad los dos con SurrounSync Setup y reiniciad el juego.",
        game_build = "Tú y %s tenéis versiones distintas de SurrounDead. Actualizad los dos el juego en Steam y reiniciadlo.",
        update_title = "SURROUNSYNC %s YA ESTÁ DISPONIBLE",
        update_msg = "Hay una nueva versión de SurrounSync. ACEPTAR abre el actualizador: instala la actualización en cuanto cierres el juego. Para jugar juntos, los dos necesitáis la misma versión.",
        update_ok = "ACEPTAR",
    },
    fr = {
        stray_title = "SAUVEGARDE COOP RESTANTE",
        stray_msg = "Ceci est une ancienne sauvegarde coop, pas ton monde. CHARGER LA MIENNE charge ta sauvegarde %s ; ensuite tu peux rejoindre ou héberger.",
        stray_ok = "CHARGER LA MIENNE",
        stray_none = "Ceci est une ancienne sauvegarde coop, pas ton monde. Charge une de tes sauvegardes depuis le menu principal.",
        session_unfinished = "Ta dernière session coop n'est pas encore terminée. Redémarre le jeu pour la terminer, puis rejoins.",
        session_rescued = "Ta dernière session coop n'a pas pu se terminer. Ta sauvegarde est comme avant de rejoindre, et ton personnage coop est gardé dans les sauvegardes (J, onglet CO-OP, BACKUPS). Tu peux rejoindre à nouveau.",
        session_closed = "Ta dernière session coop n'a pas pu se terminer. Ta sauvegarde est comme avant de rejoindre. Tu peux rejoindre à nouveau.",
        no_host = "Aucun hôte n'est encore connecté. Ton ami doit être en jeu avec SurrounSync et choisir HOST.",
        backup_failed = "Impossible de sauvegarder ta partie, tu ne peux donc pas rejoindre. Vérifie l'espace disque libre et que le jeu peut écrire dans son dossier de sauvegardes.",
        path_broken = "SurrounSync n'accède pas à ton dossier de sauvegardes (ton nom d'utilisateur Windows contient des lettres qu'il ne peut pas utiliser). Ferme le jeu, lance SurrounSync Setup et clique sur FIX.",
        disk_full = "Ton disque est plein : la sauvegarde n'a pas pu être copiée et tu ne peux pas rejoindre. Libère de l'espace et réessaie.",
        files_blocked = "Windows a empêché SurrounSync d'écrire la copie de sauvegarde (antivirus ou fichiers en lecture seule ?). Lance SurrounSync Setup et clique sur FIX, ou autorise le jeu dans ton antivirus.",
        cant_save_here = "Ton jeu n'a pas pu sauvegarder ici, tu ne peux donc pas encore rejoindre. Va à un endroit où la sauvegarde fonctionne et réessaie.",
        cant_identify = "Impossible d'identifier ta sauvegarde actuelle, tu ne peux donc pas rejoindre. Envoie un rapport de bug.",
        load_own_first = "Charge d'abord une de tes sauvegardes, puis rejoins.",
        peer_older = "%s a une ancienne version de SurrounSync. Il faut la mettre à jour avec SurrounSync Setup, puis redémarrer le jeu tous les deux.",
        me_older = "Ta version de SurrounSync est plus ancienne que celle de %s. Mets-la à jour avec SurrounSync Setup et redémarre le jeu.",
        version_differs = "Toi et %s avez des versions différentes de SurrounSync. Mettez-vous à jour tous les deux avec SurrounSync Setup et redémarrez le jeu.",
        game_build = "Toi et %s avez des versions différentes de SurrounDead. Mettez le jeu à jour tous les deux sur Steam et redémarrez-le.",
        update_title = "SURROUNSYNC %s EST DISPONIBLE",
        update_msg = "Une nouvelle version de SurrounSync est prête. ACCEPTER ouvre l'outil de mise à jour : il l'installe dès que tu fermes le jeu. Pour jouer ensemble, vous devez avoir la même version.",
        update_ok = "ACCEPTER",
    },
    pt = {
        stray_title = "SAVE COOP QUE SOBROU",
        stray_msg = "Este é um save cooperativo que sobrou, não o seu mundo. CARREGAR O MEU carrega o seu save %s; depois você pode entrar ou hospedar.",
        stray_ok = "CARREGAR O MEU",
        stray_none = "Este é um save cooperativo que sobrou, não o seu mundo. Carregue um dos seus saves no menu principal.",
        session_unfinished = "Sua última sessão cooperativa ainda não terminou. Reinicie o jogo para concluí-la e depois entre.",
        session_rescued = "Sua última sessão co-op não pôde ser concluída. Seu save está como antes de entrar, e seu personagem do co-op está guardado nos backups (J, aba CO-OP, BACKUPS). Você já pode entrar de novo.",
        session_closed = "Sua última sessão co-op não pôde ser concluída. Seu save está como antes de entrar. Você já pode entrar de novo.",
        no_host = "Nenhum anfitrião conectado ainda. Seu amigo precisa estar no jogo com SurrounSync e escolher HOST.",
        backup_failed = "Não foi possível fazer backup do seu save, então você não pode entrar. Verifique o espaço livre no disco e se o jogo consegue gravar na pasta de saves.",
        path_broken = "O SurrounSync não consegue acessar sua pasta de saves (seu nome de usuário do Windows tem letras que ele não pode usar). Feche o jogo, abra o SurrounSync Setup e clique em FIX.",
        disk_full = "Seu disco está cheio, então não foi possível fazer backup do save e você não pode entrar. Libere espaço e tente de novo.",
        files_blocked = "O Windows impediu o SurrounSync de gravar o backup (antivírus ou arquivos somente leitura?). Abra o SurrounSync Setup e clique em FIX, ou libere o jogo no antivírus.",
        cant_save_here = "Seu jogo não conseguiu salvar aqui, então você ainda não pode entrar. Vá para um lugar onde salvar funcione e tente de novo.",
        cant_identify = "Não foi possível identificar seu save atual, então você não pode entrar. Envie um relatório de bug.",
        load_own_first = "Primeiro carregue um dos seus saves e depois entre.",
        peer_older = "%s está com uma versão antiga do SurrounSync. É preciso atualizar pelo SurrounSync Setup e depois os dois reiniciarem o jogo.",
        me_older = "Sua versão do SurrounSync é mais antiga que a de %s. Atualize pelo SurrounSync Setup e reinicie o jogo.",
        version_differs = "Você e %s estão com versões diferentes do SurrounSync. Atualizem os dois pelo SurrounSync Setup e reiniciem o jogo.",
        game_build = "Você e %s estão com versões diferentes do SurrounDead. Atualizem os dois o jogo na Steam e reiniciem.",
        update_title = "SURROUNSYNC %s CHEGOU",
        update_msg = "Uma nova versão do SurrounSync está pronta. ACEITAR abre o atualizador: ele instala a atualização assim que você fechar o jogo. Para jogar juntos, os dois precisam da mesma versão.",
        update_ok = "ACEITAR",
    },
}
i18n.LANGS = T

local forced, auto = nil, nil

-- "auto", "" or nil = follow Windows; anything else must be a listed language
function i18n.set(code)
    code = code and code:lower():match("^%a%a") or nil
    forced = code and T[code] and code or nil
    return forced ~= nil or code == nil or code == "au"
end

function i18n.lang()
    if forced then return forced end
    if not auto then
        local ok, l = pcall(function() return require("mirror.link").lobby() end)
        local code = ok and type(l) == "table" and type(l.lang) == "string" and l.lang:lower():match("^%a%a") or nil
        if code then auto = T[code] and code or "en" end
    end
    return auto or "en"
end

function i18n.t(key, ...)
    local s = T[i18n.lang()][key] or T.en[key] or key
    if select("#", ...) > 0 then
        local ok, out = pcall(string.format, s, ...)
        if ok then return out end
        out = T.en[key] and select(2, pcall(string.format, T.en[key], ...))
        return type(out) == "string" and out or s
    end
    return s
end

return i18n
