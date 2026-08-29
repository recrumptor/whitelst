#!/bin/sh

# Имя интерфейса в OpenWrt и метка пира в Description
IFACE="awg1"
PEER_DESC="WARPv1_55"

# Узел для проверки доступности интернета через VPN
PING_TARGET="172.16.0.1"

# Таймаут блокировки нерабочего сервера в секундах (5 минут = 300 секунд)
BAD_TIMEOUT=300
CACHE_FILE="/tmp/warp_bad_endpoints"

# Ваш список эндпоинтов в порядке возрастания пинга (DME -> ARN)
ENDPOINTS="
8.35.211.213:2408
8.47.69.84:2408
8.39.214.241:2408
8.39.204.209:2408
8.39.125.181:2408
8.34.146.80:2408
162.159.195.146:2408
8.6.112.62:2408
188.114.99.69:2408
188.114.98.56:2408
8.34.70.26:2408
188.114.96.230:2408
162.159.192.44:2408
188.114.97.42:2408
"

# 1. Поиск индекса пира по его описанию (Используем amneziawg вместо wireguard)
PEER_INDEX=""
INDEX=0
while true; do
    DESC=$(uci get network.@amneziawg_${IFACE}[$INDEX].description 2>/dev/null)
    if [ -z "$DESC" ]; then
        break
    fi
    if [ "$DESC" = "$PEER_DESC" ]; then
        PEER_INDEX=$INDEX
        break
    fi
    INDEX=$((INDEX + 1))
done

if [ -z "$PEER_INDEX" ]; then
    logger -t warp_pool "Ошибка: Пир с описанием '$PEER_DESC' не найден в AmneziaWG интерфейсе $IFACE."
    exit 1
fi

# 2. Проверка связи через текущий активный эндпоинт
ping -I $IFACE -c 3 -W 2 $PING_TARGET > /dev/null 2>&1
if [ $? -eq 0 ]; then
    exit 0
fi

# 3. Если связи нет — определяем текущий эндпоинт и заносим в кэш сбоев
CUR_HOST=$(uci get network.@amneziawg_${IFACE}[$PEER_INDEX].endpoint_host 2>/dev/null)
CUR_PORT=$(uci get network.@amneziawg_${IFACE}[$PEER_INDEX].endpoint_port 2>/dev/null)
CURRENT_EP="${CUR_HOST}:${CUR_PORT}"
NOW=$(date +%s)

touch $CACHE_FILE
sed -i "/^${CURRENT_EP} /d" $CACHE_FILE
echo "$CURRENT_EP $NOW" >> $CACHE_FILE

logger -t warp_pool "Внимание: Эндпоинт $CURRENT_EP недоступен. Начинаем перебор сначала..."

# 4. Цикл перебора эндпоинтов ВСЕГДА СНАЧАЛА списка
NEW_EP=""
for candidate in $ENDPOINTS; do
    BAD_TIME=$(grep "^${candidate} " $CACHE_FILE | awk '{print $2}')
    
    if [ -n "$BAD_TIME" ]; then
        TIME_DIFF=$((NOW - BAD_TIME))
        if [ $TIME_DIFF -lt $BAD_TIMEOUT ]; then
            REMAINING_BLOCK=$((BAD_TIMEOUT - TIME_DIFF))
            logger -t warp_pool "Пропуск $candidate (был нерабочим еще $REMAINING_BLOCK сек)"
            continue
        fi
    fi

    CAND_HOST=$(echo $candidate | cut -d':' -f1)
    CAND_PORT=$(echo $candidate | cut -d':' -f2)

    logger -t warp_pool "Тестируем сервер: $candidate..."
    
    uci set network.@amneziawg_${IFACE}[$PEER_INDEX].endpoint_host="$CAND_HOST"
    uci set network.@amneziawg_${IFACE}[$PEER_INDEX].endpoint_port="$CAND_PORT"
    uci commit network
    ifdown $IFACE && ifup $IFACE
    
    sleep 3

    ping -I $IFACE -c 2 -W 1 $PING_TARGET > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        logger -t warp_pool "Успешно! Эндпоинт $candidate работает."
        sed -i "/^${candidate} /d" $CACHE_FILE
        NEW_EP=$candidate
        break
    else
        NOW_UPDATE=$(date +%s)
        sed -i "/^${candidate} /d" $CACHE_FILE
        echo "$candidate $NOW_UPDATE" >> $CACHE_FILE
    fi
done

# 5. Защита от тотального падения
if [ -z "$NEW_EP" ]; then
    FIRST_EP=$(echo $ENDPOINTS | awk '{print $1}')
    FIRST_HOST=$(echo $FIRST_EP | cut -d':' -f1)
    FIRST_PORT=$(echo $FIRST_EP | cut -d':' -f2)
    
    logger -t warp_pool "Критическая ошибка: Рабочих серверов нет. Сброс на первый ($FIRST_EP)."
    
    > $CACHE_FILE
    uci set network.@amneziawg_${IFACE}[$PEER_INDEX].endpoint_host="$FIRST_HOST"
    uci set network.@amneziawg_${IFACE}[$PEER_INDEX].endpoint_port="$FIRST_PORT"
    uci commit network
    ifdown $IFACE && ifup $IFACE
fi

