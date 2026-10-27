// Логика llm-proxy (njs). Подключается в default.conf.template через js_import.
//
// На каждый POST /v1/chat/completions:
//   1. loadConfig читает /etc/llm-proxy/config.json (каждый раз заново, поэтому смена режима,
//      модели или адреса действует со следующего запроса без перезапуска и reload);
//   2. rewriteBody подменяет в теле model на модель режима, остальные поля не трогает;
//   3. route кладёт тело и адрес upstream в переменные и переводит запрос во внутренний
//      @router или @ollama (locations.conf), где proxy_pass передаёт ответ потоком.
//
// Почему не js_set и не r.subrequest: js_set не видит тело запроса, а ответ подзапроса и
// ngx.fetch njs собирает целиком — SSE пришёл бы одним куском в конце. Поэтому njs только
// готовит запрос, а передачу делает proxy_pass.
//
// Ключ роутера берётся из окружения (env ROUTER_KEY в nginx.conf) и никуда не пишется.

import fs from 'fs';

const CONFIG_PATH = '/etc/llm-proxy/config.json';
const MODES = ['router', 'ollama'];
// Ключ в общем словаре (js_shared_dict_zone llm_proxy): последняя корректная конфигурация.
const LAST_GOOD = 'last_good';

function isObject(v) {
    return v !== null && typeof v === 'object' && !Array.isArray(v);
}

// Пустая строка — конфигурация годится; иначе — что с ней не так (для лога).
function validate(cfg) {
    if (!isObject(cfg)) {
        return 'ожидается JSON-объект';
    }
    if (MODES.indexOf(cfg.mode) < 0) {
        return 'mode должен быть "router" или "ollama"';
    }
    for (let i = 0; i < MODES.length; i++) {
        const m = MODES[i];
        if (!isObject(cfg[m]) || typeof cfg[m].url !== 'string' || typeof cfg[m].model !== 'string') {
            return `нужен раздел ${m} со строками url и model`;
        }
    }
    const active = cfg[cfg.mode];
    if (!/^https?:\/\/[^\/\s]+/.test(active.url)) {
        return `${cfg.mode}.url должен начинаться с http:// или https://`;
    }
    if (!active.model) {
        return `${cfg.mode}.model пуст`;
    }
    return '';
}

// Читает и проверяет config.json. При ошибке пишет её в лог и возвращает последнюю корректную
// конфигурацию; если корректной ещё не было с запуска — null (запрос получит 503).
function loadConfig(r) {
    const store = ngx.shared.llm_proxy;
    let problem;
    try {
        const cfg = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
        problem = validate(cfg);
        if (!problem) {
            const good = {
                mode: cfg.mode,
                router: { url: cfg.router.url, model: cfg.router.model },
                ollama: { url: cfg.ollama.url, model: cfg.ollama.model },
            };
            const text = JSON.stringify(good);
            if (store.get(LAST_GOOD) !== text) {
                store.set(LAST_GOOD, text);
            }
            return good;
        }
    } catch (e) {
        problem = e.message;
    }
    const last = store.get(LAST_GOOD);
    r.error(`llm-proxy: ${CONFIG_PATH} некорректен (${problem}); ` +
        (last ? 'используется последняя корректная конфигурация'
              : 'корректной конфигурации не было с запуска, запрос отклонён (503)'));
    return last ? JSON.parse(last) : null;
}

// Тело запроса с model, заменённой на модель режима ($llm_model, его выставляет route).
// Бросает исключение, если тело — не JSON-объект.
function rewriteBody(r) {
    const body = JSON.parse(r.requestText || '');
    if (!isObject(body)) {
        throw new Error('тело должно быть JSON-объектом');
    }
    body.model = r.variables.llm_model;
    return JSON.stringify(body);
}

function fail(r, status, message) {
    r.headersOut['Content-Type'] = 'application/json';
    r.return(status, JSON.stringify({ error: { message: message, type: 'llm_proxy_error' } }));
}

function route(r) {
    const cfg = loadConfig(r);
    if (!cfg) {
        return fail(r, 503, 'llm-proxy: нет корректной конфигурации (config.json)');
    }
    const target = cfg[cfg.mode];
    if (cfg.mode === 'router' && !process.env.ROUTER_KEY) {
        r.error('llm-proxy: ROUTER_KEY не задан, режим router недоступен');
        return fail(r, 503, 'llm-proxy: режим router не настроен');
    }

    r.variables.llm_mode = cfg.mode;
    r.variables.llm_model = target.model;
    let body;
    try {
        body = rewriteBody(r);
    } catch (e) {
        return fail(r, 400, 'llm-proxy: тело запроса должно быть JSON-объектом');
    }
    r.variables.llm_body = body;
    r.variables.llm_url = target.url.replace(/\/+$/, '') + '/chat/completions';
    r.internalRedirect('@' + cfg.mode);
}

// $llm_router_auth: заголовок Authorization для режима router.
function routerAuth(r) {
    return 'Bearer ' + (process.env.ROUTER_KEY || '');
}

export default { route, routerAuth, loadConfig, rewriteBody };
