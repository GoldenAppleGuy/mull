#!/usr/bin/env python3
# Writes the translations into prefs/Resources/<language>.lproj:
#   Root.strings  - the settings page (Root.plist labels, footers and titles, plus text set in code)
#   Tweak.strings - the countdown screen and swipe action (read by the tweak from the settings bundle)
# Keys are the English text. Run after changing any user-visible string; it fails if a string in
# Root.plist has no translation. Output is XML property lists, which iOS reads as .strings files.
import os, plistlib, sys

HERE = os.path.dirname(os.path.abspath(__file__))
RESOURCES = os.path.join(HERE, '..', 'Resources')

F_MESSAGES = 'Tap the Send button during the countdown to cancel. Values set to Same use the regular delay.'
F_SHORT = 'Messages shorter than this many characters send right away. Off counts down for every message regardless of length.'
F_CONVERSATIONS = 'Swipe a conversation to the left in Messages to turn its countdown off or on. A bolt beside its date shows that the countdown is off.'
F_CALLS = 'Phone and FaceTime calls count down before they start. Emergency calls are never delayed.'

# Order of each row: de, es, fr, it, ja, ko, nl, pt-BR, ru, zh-Hans, zh-Hant, tr, pl
LANGUAGES = ['de', 'es', 'fr', 'it', 'ja', 'ko', 'nl', 'pt-BR', 'ru', 'zh-Hans', 'zh-Hant', 'tr', 'pl']
ROOT = {
    'Enabled': ['Aktiviert', 'Activado', 'Activé', 'Attivo', '有効', '활성화', 'Ingeschakeld', 'Ativado', 'Включено', '启用', '啟用', 'Etkin', 'Włączone'],
    'Messages': ['Nachrichten', 'Mensajes', 'Messages', 'Messaggi', 'メッセージ', '메시지', 'Berichten', 'Mensagens', 'Сообщения', '信息', '訊息', 'Mesajlar', 'Wiadomości'],
    F_MESSAGES: [
        'Tippe während des Countdowns auf die Senden-Taste, um abzubrechen. Werte auf „Wie normal“ nutzen die normale Verzögerung.',
        'Toca el botón de enviar durante la cuenta atrás para cancelar. Los valores en «Igual» usan el retraso normal.',
        'Touchez le bouton d’envoi pendant le compte à rebours pour annuler. Les valeurs réglées sur « Identique » utilisent le délai habituel.',
        'Tocca il pulsante di invio durante il conto alla rovescia per annullare. I valori impostati su «Uguale» usano il ritardo normale.',
        'カウントダウン中に送信ボタンをタップするとキャンセルされます。「同じ」に設定した値は通常の待ち時間を使います。',
        '카운트다운 중에 보내기 버튼을 탭하면 취소됩니다. ‘동일’로 설정한 값은 기본 지연 시간을 사용합니다.',
        'Tik tijdens het aftellen op de verzendknop om te annuleren. Waarden die op ‘Gelijk’ staan, gebruiken de gewone vertraging.',
        'Toque no botão de enviar durante a contagem regressiva para cancelar. Valores definidos como “Igual” usam o atraso normal.',
        'Нажмите кнопку отправки во время отсчёта, чтобы отменить. Значения «Как обычно» используют обычную задержку.',
        '倒计时期间轻点“发送”按钮即可取消。设为“相同”的值使用常规延迟。',
        '倒數期間點一下「傳送」按鈕即可取消。設為「相同」的值使用一般延遲。',
        'İptal etmek için geri sayım sırasında Gönder düğmesine dokunun. “Aynı” olarak ayarlanan değerler normal gecikmeyi kullanır.',
        'Stuknij przycisk wysyłania podczas odliczania, aby anulować. Wartości ustawione na „Tak samo” używają zwykłego opóźnienia.',
    ],
    'Delay': ['Verzögerung', 'Retraso', 'Délai', 'Ritardo', '待ち時間', '지연 시간', 'Vertraging', 'Atraso', 'Задержка', '延迟', '延遲', 'Gecikme', 'Opóźnienie'],
    'First Message': ['Erste Nachricht', 'Primer mensaje', 'Premier message', 'Primo messaggio', '最初のメッセージ', '첫 메시지', 'Eerste bericht', 'Primeira mensagem', 'Первое сообщение', '首条信息', '第一則訊息', 'İlk Mesaj', 'Pierwsza wiadomość'],
    'Attachments': ['Anhänge', 'Adjuntos', 'Pièces jointes', 'Allegati', '添付ファイル', '첨부 파일', 'Bijlagen', 'Anexos', 'Вложения', '附件', '附件', 'Ekler', 'Załączniki'],
    'Same': ['Wie normal', 'Igual', 'Identique', 'Uguale', '同じ', '동일', 'Gelijk', 'Igual', 'Как обычно', '相同', '相同', 'Aynı', 'Tak samo'],
    'Short Messages': ['Kurze Nachrichten', 'Mensajes cortos', 'Messages courts', 'Messaggi brevi', '短いメッセージ', '짧은 메시지', 'Korte berichten', 'Mensagens curtas', 'Короткие сообщения', '短信息', '短訊息', 'Kısa Mesajlar', 'Krótkie wiadomości'],
    F_SHORT: [
        'Nachrichten, die kürzer als diese Zeichenzahl sind, werden sofort gesendet. „Aus“ lässt für jede Nachricht den Countdown laufen, unabhängig von der Länge.',
        'Los mensajes con menos caracteres que este número se envían de inmediato. «No» aplica la cuenta atrás a todos los mensajes, sea cual sea su longitud.',
        'Les messages de moins de caractères que ce nombre sont envoyés tout de suite. « Désactivé » applique le compte à rebours à tous les messages, quelle que soit leur longueur.',
        'I messaggi con meno caratteri di questo numero vengono inviati subito. «No» applica il conto alla rovescia a ogni messaggio, a prescindere dalla lunghezza.',
        'この文字数より短いメッセージはすぐに送信されます。「オフ」にすると、長さに関係なくすべてのメッセージでカウントダウンします。',
        '이 글자 수보다 짧은 메시지는 바로 전송됩니다. ‘끔’으로 두면 길이와 상관없이 모든 메시지에 카운트다운이 적용됩니다.',
        'Berichten met minder tekens dan dit aantal worden meteen verzonden. ‘Uit’ laat voor elk bericht de aftelling lopen, ongeacht de lengte.',
        'Mensagens com menos caracteres que este número são enviadas na hora. “Desativado” faz a contagem regressiva em todas as mensagens, qualquer que seja o tamanho.',
        'Сообщения короче этого числа символов отправляются сразу. «Выкл.» запускает отсчёт для каждого сообщения независимо от длины.',
        '字数少于此数值的信息会立即发送。“关闭”表示无论长度，所有信息都会倒计时。',
        '字數少於此數值的訊息會立即傳送。「關閉」表示無論長度，所有訊息都會倒數。',
        'Bu karakter sayısından kısa mesajlar hemen gönderilir. “Kapalı”, uzunluğa bakılmaksızın her mesaj için geri sayım yapar.',
        'Wiadomości krótsze niż ta liczba znaków wysyłane są od razu. „Wył.” odlicza przy każdej wiadomości, niezależnie od długości.',
    ],
    'Minimum Length': ['Mindestlänge', 'Longitud mínima', 'Longueur minimale', 'Lunghezza minima', '最小の長さ', '최소 길이', 'Minimale lengte', 'Tamanho mínimo', 'Минимальная длина', '最短长度', '最短長度', 'En Kısa Uzunluk', 'Minimalna długość'],
    'Off': ['Aus', 'No', 'Désactivé', 'No', 'オフ', '끔', 'Uit', 'Desativado', 'Выкл.', '关闭', '關閉', 'Kapalı', 'Wył.'],
    'Appearance': ['Darstellung', 'Apariencia', 'Apparence', 'Aspetto', '外観', '모양', 'Weergave', 'Aparência', 'Внешний вид', '外观', '外觀', 'Görünüm', 'Wygląd'],
    'Countdown Color': ['Farbe des Countdowns', 'Color de la cuenta atrás', 'Couleur du compte à rebours', 'Colore del conto alla rovescia', 'カウントダウンの色', '카운트다운 색상', 'Kleur van de aftelling', 'Cor da contagem regressiva', 'Цвет обратного отсчёта', '倒计时颜色', '倒數顏色', 'Geri Sayım Rengi', 'Kolor odliczania'],
    'Red': ['Rot', 'Rojo', 'Rouge', 'Rosso', '赤', '빨간색', 'Rood', 'Vermelho', 'Красный', '红色', '紅色', 'Kırmızı', 'Czerwony'],
    'Orange': ['Orange', 'Naranja', 'Orange', 'Arancione', 'オレンジ', '주황색', 'Oranje', 'Laranja', 'Оранжевый', '橙色', '橙色', 'Turuncu', 'Pomarańczowy'],
    'Pink': ['Pink', 'Rosa', 'Rose', 'Rosa', 'ピンク', '분홍색', 'Roze', 'Rosa', 'Розовый', '粉色', '粉紅色', 'Pembe', 'Różowy'],
    'Purple': ['Lila', 'Morado', 'Violet', 'Viola', '紫', '보라색', 'Paars', 'Roxo', 'Фиолетовый', '紫色', '紫色', 'Mor', 'Fioletowy'],
    'Blue': ['Blau', 'Azul', 'Bleu', 'Blu', '青', '파란색', 'Blauw', 'Azul', 'Синий', '蓝色', '藍色', 'Mavi', 'Niebieski'],
    'Green': ['Grün', 'Verde', 'Vert', 'Verde', '緑', '초록색', 'Groen', 'Verde', 'Зелёный', '绿色', '綠色', 'Yeşil', 'Zielony'],
    'Gray': ['Grau', 'Gris', 'Gris', 'Grigio', 'グレー', '회색', 'Grijs', 'Cinza', 'Серый', '灰色', '灰色', 'Gri', 'Szary'],
    'Haptics': ['Haptik', 'Háptica', 'Haptique', 'Aptico', '触覚', '햅틱', 'Haptiek', 'Tátil', 'Вибрация', '触感', '觸覺', 'Dokunsal', 'Wibracje'],
    'Progress Ring': ['Fortschrittsring', 'Anillo de progreso', 'Anneau de progression', 'Anello di avanzamento', '進行リング', '진행 링', 'Voortgangsring', 'Anel de progresso', 'Кольцо прогресса', '进度环', '進度環', 'İlerleme Halkası', 'Pierścień postępu'],
    'Conversations': ['Unterhaltungen', 'Conversaciones', 'Conversations', 'Conversazioni', '会話', '대화', 'Gesprekken', 'Conversas', 'Беседы', '对话', '對話', 'Konuşmalar', 'Rozmowy'],
    F_CONVERSATIONS: [
        'Wische in Nachrichten eine Unterhaltung nach links, um ihren Countdown aus- oder einzuschalten. Ein Blitz neben dem Datum zeigt, dass der Countdown aus ist.',
        'Desliza una conversación hacia la izquierda en Mensajes para activar o desactivar su cuenta atrás. Un rayo junto a la fecha indica que la cuenta atrás está desactivada.',
        'Balayez une conversation vers la gauche dans Messages pour activer ou désactiver son compte à rebours. Un éclair à côté de la date indique que le compte à rebours est désactivé.',
        'Scorri una conversazione verso sinistra in Messaggi per attivare o disattivare il suo conto alla rovescia. Un fulmine accanto alla data indica che il conto alla rovescia è disattivato.',
        'メッセージで会話を左にスワイプすると、その会話のカウントダウンをオフ／オンにできます。日付の横の稲妻は、カウントダウンがオフであることを示します。',
        '메시지에서 대화를 왼쪽으로 쓸어 넘기면 해당 대화의 카운트다운을 끄거나 켤 수 있습니다. 날짜 옆의 번개 표시는 카운트다운이 꺼져 있음을 나타냅니다.',
        'Veeg in Berichten een gesprek naar links om de aftelling ervan uit of aan te zetten. Een bliksemflits naast de datum laat zien dat de aftelling uit staat.',
        'Deslize uma conversa para a esquerda em Mensagens para desativar ou ativar a contagem regressiva dela. Um raio ao lado da data indica que a contagem está desativada.',
        'Смахните беседу влево в «Сообщениях», чтобы выключить или включить для неё отсчёт. Молния рядом с датой означает, что отсчёт выключен.',
        '在“信息”中向左轻扫某个对话，即可关闭或开启其倒计时。日期旁的闪电表示该对话已关闭倒计时。',
        '在「訊息」中向左滑動某個對話，即可關閉或開啟其倒數。日期旁的閃電表示該對話已關閉倒數。',
        'Mesajlar’da bir konuşmayı sola kaydırarak geri sayımını kapatın veya açın. Tarihin yanındaki şimşek, geri sayımın kapalı olduğunu gösterir.',
        'Przesuń rozmowę w lewo w aplikacji Wiadomości, aby wyłączyć lub włączyć jej odliczanie. Błyskawica obok daty oznacza, że odliczanie jest wyłączone.',
    ],
    'Reset Skipped Conversations': ['Übersprungene Unterhaltungen zurücksetzen', 'Restablecer conversaciones omitidas', 'Réinitialiser les conversations ignorées', 'Ripristina conversazioni escluse', 'スキップした会話をリセット', '건너뛴 대화 재설정', 'Overgeslagen gesprekken herstellen', 'Redefinir conversas ignoradas', 'Сбросить пропущенные беседы', '重置已跳过的对话', '重置已略過的對話', 'Atlanan Konuşmaları Sıfırla', 'Zresetuj pominięte rozmowy'],
    'Calls': ['Anrufe', 'Llamadas', 'Appels', 'Chiamate', '通話', '통화', 'Oproepen', 'Chamadas', 'Звонки', '通话', '通話', 'Aramalar', 'Połączenia'],
    F_CALLS: [
        'Telefon- und FaceTime-Anrufe zählen herunter, bevor sie beginnen. Notrufe werden nie verzögert.',
        'Las llamadas telefónicas y de FaceTime hacen una cuenta atrás antes de empezar. Las llamadas de emergencia nunca se retrasan.',
        'Les appels téléphoniques et FaceTime affichent un compte à rebours avant de démarrer. Les appels d’urgence ne sont jamais retardés.',
        'Le chiamate telefoniche e FaceTime fanno un conto alla rovescia prima di iniziare. Le chiamate di emergenza non vengono mai ritardate.',
        '電話とFaceTimeの通話は、開始前にカウントダウンします。緊急通報が遅れることはありません。',
        '전화와 FaceTime 통화는 시작하기 전에 카운트다운합니다. 긴급 통화는 절대 지연되지 않습니다.',
        'Telefoon- en FaceTime-oproepen tellen af voordat ze beginnen. Noodoproepen worden nooit vertraagd.',
        'Chamadas telefônicas e de FaceTime fazem uma contagem regressiva antes de começar. Chamadas de emergência nunca são atrasadas.',
        'Перед началом телефонных звонков и звонков FaceTime идёт обратный отсчёт. Экстренные вызовы никогда не задерживаются.',
        '电话和 FaceTime 通话会在开始前倒计时。紧急呼叫绝不会被延迟。',
        '電話和 FaceTime 通話會在開始前倒數。緊急通話絕不會被延遲。',
        'Telefon ve FaceTime aramaları başlamadan önce geri sayım yapar. Acil durum aramaları asla geciktirilmez.',
        'Połączenia telefoniczne i FaceTime są poprzedzone odliczaniem. Połączenia alarmowe nigdy nie są opóźniane.',
    ],
    'Call Countdown': ['Anruf-Countdown', 'Cuenta atrás de llamadas', 'Compte à rebours des appels', 'Conto alla rovescia chiamate', '通話カウントダウン', '통화 카운트다운', 'Aftelling voor oproepen', 'Contagem de chamadas', 'Отсчёт перед звонком', '通话倒计时', '通話倒數', 'Arama Geri Sayımı', 'Odliczanie połączeń'],
    # Text set in code
    's': ['s', 's', 's', 's', '秒', '초', 's', 's', 'с', '秒', '秒', 'sn', 's'],
    'Conversations Reset': ['Unterhaltungen zurückgesetzt', 'Conversaciones restablecidas', 'Conversations réinitialisées', 'Conversazioni ripristinate', '会話をリセットしました', '대화가 재설정되었습니다', 'Gesprekken hersteld', 'Conversas redefinidas', 'Беседы сброшены', '对话已重置', '對話已重置', 'Konuşmalar Sıfırlandı', 'Rozmowy zresetowane'],
    'Every conversation uses the countdown again.': ['Jede Unterhaltung nutzt den Countdown wieder.', 'Todas las conversaciones vuelven a usar la cuenta atrás.', 'Toutes les conversations utilisent de nouveau le compte à rebours.', 'Ogni conversazione usa di nuovo il conto alla rovescia.', 'すべての会話でカウントダウンが再び使われます。', '모든 대화에 다시 카운트다운이 적용됩니다.', 'Elk gesprek gebruikt de aftelling weer.', 'Todas as conversas voltam a usar a contagem regressiva.', 'Во всех беседах снова используется обратный отсчёт.', '所有对话将再次使用倒计时。', '所有對話將再次使用倒數。', 'Her konuşma yine geri sayımı kullanır.', 'Każda rozmowa znów używa odliczania.'],
    'OK': ['OK', 'OK', 'OK', 'OK', 'OK', '확인', 'OK', 'OK', 'ОК', '好', '好', 'Tamam', 'OK'],
    'Enter Value': ['Wert eingeben', 'Introducir valor', 'Saisir une valeur', 'Inserisci valore', '値を入力', '값 입력', 'Waarde invoeren', 'Inserir valor', 'Введите значение', '输入数值', '輸入數值', 'Değer Girin', 'Wpisz wartość'],
    'From %1$@ to %2$@.': ['Von %1$@ bis %2$@.', 'De %1$@ a %2$@.', 'De %1$@ à %2$@.', 'Da %1$@ a %2$@.', '%1$@〜%2$@', '%1$@~%2$@', 'Van %1$@ tot %2$@.', 'De %1$@ a %2$@.', 'От %1$@ до %2$@.', '%1$@ 至 %2$@', '%1$@ 至 %2$@', '%1$@ ile %2$@ arası.', 'Od %1$@ do %2$@.'],
    'Set': ['Übernehmen', 'Aplicar', 'Valider', 'Imposta', '設定', '설정', 'Stel in', 'Definir', 'Готово', '设定', '設定', 'Ayarla', 'Ustaw'],
    'Cancel': ['Abbrechen', 'Cancelar', 'Annuler', 'Annulla', 'キャンセル', '취소', 'Annuleer', 'Cancelar', 'Отмена', '取消', '取消', 'Vazgeç', 'Anuluj'],
}

# The countdown screen and swipe action, read by the tweak
TWEAK = {
    'Skip Countdown': ['Countdown überspringen', 'Omitir cuenta atrás', 'Ignorer le compte à rebours', 'Salta conto alla rovescia', 'カウントダウンをスキップ', '카운트다운 건너뛰기', 'Aftelling overslaan', 'Pular contagem', 'Пропустить отсчёт', '跳过倒计时', '略過倒數', 'Geri Sayımı Atla', 'Pomiń odliczanie'],
    'Use Countdown': ['Countdown verwenden', 'Usar cuenta atrás', 'Utiliser le compte à rebours', 'Usa conto alla rovescia', 'カウントダウンを使用', '카운트다운 사용', 'Aftelling gebruiken', 'Usar contagem', 'Включить отсчёт', '使用倒计时', '使用倒數', 'Geri Sayımı Kullan', 'Używaj odliczania'],
    'Cancel': ROOT['Cancel'],
    'Call Now': ['Jetzt anrufen', 'Llamar ahora', 'Appeler maintenant', 'Chiama ora', '今すぐ発信', '지금 통화', 'Nu bellen', 'Ligar agora', 'Позвонить сейчас', '立即拨打', '立即撥打', 'Şimdi Ara', 'Zadzwoń teraz'],
    'Phone Call': ['Telefonanruf', 'Llamada telefónica', 'Appel téléphonique', 'Chiamata', '電話', '전화', 'Telefoongesprek', 'Chamada telefônica', 'Телефонный звонок', '电话', '電話', 'Telefon Araması', 'Połączenie telefoniczne'],
    'FaceTime Audio': ['FaceTime Audio', 'Audio de FaceTime', 'FaceTime Audio', 'FaceTime Audio', 'FaceTimeオーディオ', 'FaceTime 오디오', 'FaceTime-audio', 'Áudio do FaceTime', 'Аудио FaceTime', 'FaceTime 通话', 'FaceTime 語音', 'FaceTime Sesli', 'FaceTime Audio'],
    'FaceTime Video': ['FaceTime Video', 'Vídeo de FaceTime', 'FaceTime Vidéo', 'FaceTime Video', 'FaceTimeビデオ', 'FaceTime 비디오', 'FaceTime-video', 'Vídeo do FaceTime', 'Видео FaceTime', 'FaceTime 视频', 'FaceTime 視訊', 'FaceTime Görüntülü', 'FaceTime Video'],
}

def check_coverage():
    root = plistlib.load(open(os.path.join(RESOURCES, 'Root.plist'), 'rb'))
    needed = set()
    for item in root['items']:
        for key in ('label', 'footerText', 'inlineLabel', 'valueSuffix', 'zeroText'):
            if key in item: needed.add(item[key])
        needed.update(item.get('validTitles', []))
    missing = sorted(needed - set(ROOT))
    if missing:
        sys.exit('No translation for: ' + ', '.join(repr(m) for m in missing))
    for table in (ROOT, TWEAK):
        for english, translated in table.items():
            if len(translated) != len(LANGUAGES):
                sys.exit(f'{english!r}: {len(translated)} translations, expected {len(LANGUAGES)}')

def main():
    check_coverage()
    for i, language in enumerate(LANGUAGES):
        folder = os.path.join(RESOURCES, language + '.lproj')
        os.makedirs(folder, exist_ok=True)
        for name, table in (('Root', ROOT), ('Tweak', TWEAK)):
            strings = {english: translated[i] for english, translated in table.items()}
            with open(os.path.join(folder, name + '.strings'), 'wb') as f:
                plistlib.dump(strings, f, fmt=plistlib.FMT_XML, sort_keys=True)
    # English too: iOS only picks from the languages a bundle lists, so without an English folder an
    # English phone would get whichever other language comes next in its language list
    folder = os.path.join(RESOURCES, 'en.lproj')
    os.makedirs(folder, exist_ok=True)
    for name, table in (('Root', ROOT), ('Tweak', TWEAK)):
        with open(os.path.join(folder, name + '.strings'), 'wb') as f:
            plistlib.dump({english: english for english in table}, f, fmt=plistlib.FMT_XML, sort_keys=True)
    print(f'English + {len(LANGUAGES)} languages, {len(ROOT)} settings strings, {len(TWEAK)} screen strings')

if __name__ == '__main__':
    main()
