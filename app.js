const todayKey = () => new Date().toISOString().slice(0, 10);
const storeKey = `eye-rest-${todayKey()}`;
const runtimeKey = "eye-rest-running-timer";
const notificationPromptedKey = "eye-rest-notification-prompted";
const defaultState = {
  sessions: 0,
  checks: {},
  foods: {},
  reminders: {
    sound: true,
    vibration: false,
    notification: false
  },
  native: {
    enabled: false,
    action: "overlay"
  },
  streak: Number(localStorage.getItem("eye-rest-streak") || 0),
  lastDay: localStorage.getItem("eye-rest-last-day") || ""
};

const state = { ...defaultState, ...JSON.parse(localStorage.getItem(storeKey) || "{}") };
state.reminders = { ...defaultState.reminders, ...(state.reminders || {}) };
state.native = { ...defaultState.native, ...(state.native || {}) };
let totalSeconds = 40 * 60;
let remainingSeconds = totalSeconds;
let timerId = null;
let breakId = null;
let deferredInstallPrompt = null;
let audioContext = null;
let timerDeadline = 0;
let breakDeadline = 0;
let isRunning = false;
let reminderLoopId = null;
const defaultTitle = document.title;

const timeLeft = document.querySelector("#timeLeft");
const ring = document.querySelector("#progressRing");
const startPause = document.querySelector("#startPause");
const resetTimer = document.querySelector("#resetTimer");
const modeButtons = document.querySelectorAll(".mode");
const timerTitle = document.querySelector("#timerTitle");
const timerHint = document.querySelector("#timerHint");
const breakPanel = document.querySelector("#breakPanel");
const breakLeft = document.querySelector("#breakLeft");
const skipBreak = document.querySelector("#skipBreak");
const sessions = document.querySelector("#sessions");
const score = document.querySelector("#score");
const streak = document.querySelector("#streak");
const examDone = document.querySelector("#examDone");
const examStatus = document.querySelector("#examStatus");
const installButton = document.querySelector("#installButton");
const reminderStatus = document.querySelector("#reminderStatus");
const testReminder = document.querySelector("#testReminder");
const nativeStatus = document.querySelector("#nativeStatus");
const nativeToggle = document.querySelector("#nativeToggle");
const nativeActionButtons = document.querySelectorAll("[data-native-action]");
let nativeBridgeBase = "";
let nativeTimerScheduled = false;
let nativeScheduleDeadline = 0;

function save() {
  localStorage.setItem(storeKey, JSON.stringify(state));
  localStorage.setItem("eye-rest-streak", String(state.streak));
  localStorage.setItem("eye-rest-last-day", state.lastDay);
}

function saveTimerRuntime() {
  if (!isRunning || !timerDeadline) {
    localStorage.removeItem(runtimeKey);
    return;
  }
  localStorage.setItem(
    runtimeKey,
    JSON.stringify({
      date: todayKey(),
      deadline: timerDeadline,
      totalSeconds
    })
  );
}

function updateStats() {
  const checked = Object.values(state.checks).filter(Boolean).length;
  const total = document.querySelectorAll("[data-check]").length;
  sessions.textContent = state.sessions;
  score.textContent = `${Math.round((checked / total) * 100)}%`;
  streak.textContent = state.streak;
  document.querySelectorAll("[data-check]").forEach((item) => {
    item.checked = Boolean(state.checks[item.dataset.check]);
  });
  document.querySelectorAll(".food").forEach((item) => {
    item.classList.toggle("done", Boolean(state.foods[item.dataset.food]));
  });
  document.querySelectorAll("[data-reminder]").forEach((item) => {
    const active = Boolean(state.reminders[item.dataset.reminder]);
    item.classList.toggle("active", active);
    item.textContent = active ? "开" : "关";
    item.setAttribute("aria-pressed", String(active));
  });
  renderNativeControls();
}

function format(seconds) {
  const minutes = Math.floor(seconds / 60).toString().padStart(2, "0");
  const secs = (seconds % 60).toString().padStart(2, "0");
  return `${minutes}:${secs}`;
}

function renderTimer() {
  timeLeft.textContent = format(remainingSeconds);
  const used = totalSeconds - remainingSeconds;
  const degrees = Math.max(0, Math.min(360, (used / totalSeconds) * 360));
  ring.style.background = `conic-gradient(var(--teal) ${degrees}deg, #e9e3d6 ${degrees}deg)`;
}

function stopTimer() {
  clearInterval(timerId);
  timerId = null;
  isRunning = false;
  timerDeadline = 0;
  cancelNativeSchedule();
  saveTimerRuntime();
  startPause.textContent = "继续";
}

function completeSession() {
  const nativeAlreadyHandled = nativeTimerScheduled && nativeScheduleDeadline && Date.now() > nativeScheduleDeadline + 2000;
  clearInterval(timerId);
  timerId = null;
  isRunning = false;
  timerDeadline = 0;
  saveTimerRuntime();
  cancelNativeSchedule();
  state.sessions += 1;
  const last = state.lastDay;
  if (last !== todayKey()) {
    state.streak = last ? state.streak + 1 : Math.max(1, state.streak);
    state.lastDay = todayKey();
  }
  save();
  updateStats();
  if (nativeAlreadyHandled) {
    reminderStatus.textContent = "电脑强提醒已由本机程序准时触发。";
  } else {
    sendReminder();
    triggerBreak();
  }
  remainingSeconds = totalSeconds;
  startPause.textContent = "开始";
  renderTimer();
}

function tickTimer() {
  if (!isRunning) return;
  remainingSeconds = Math.max(0, Math.ceil((timerDeadline - Date.now()) / 1000));
  renderTimer();
  if (remainingSeconds <= 0) completeSession();
}

function getReminderAudioContext() {
  const AudioContext = window.AudioContext || window.webkitAudioContext;
  if (!AudioContext) return null;
  audioContext ||= new AudioContext();
  return audioContext;
}

async function prepareReminderSound() {
  const context = getReminderAudioContext();
  if (context?.state === "suspended") await context.resume();
}

async function prepareWebReminder() {
  if (state.reminders.sound) {
    try {
      await prepareReminderSound();
    } catch {
      reminderStatus.textContent = "浏览器暂时无法启用提示音，请检查网页声音权限。";
    }
  }

  if (!("Notification" in window) || localStorage.getItem(notificationPromptedKey)) return;
  localStorage.setItem(notificationPromptedKey, "1");
  if (Notification.permission !== "default") return;

  const permission = await Notification.requestPermission();
  if (permission === "granted") {
    state.reminders.notification = true;
    save();
    updateStats();
    reminderStatus.textContent = "提示音和系统通知已就绪；切换到其他页面也能收到提醒。";
  } else {
    reminderStatus.textContent = "系统通知未开启，倒计时结束时仍会播放提示音并更新页面标题。";
  }
}

async function playReminderSound(delay = 0, frequency = 880) {
  const context = getReminderAudioContext();
  if (!context) return;
  if (context.state === "suspended") await context.resume();
  const oscillator = context.createOscillator();
  const gain = context.createGain();
  const now = context.currentTime + delay;
  const duration = 0.52;
  oscillator.type = "triangle";
  oscillator.frequency.setValueAtTime(frequency, now);
  oscillator.frequency.exponentialRampToValueAtTime(frequency * 0.82, now + duration);
  gain.gain.setValueAtTime(0.0001, now);
  gain.gain.exponentialRampToValueAtTime(0.34, now + 0.025);
  gain.gain.setValueAtTime(0.34, now + 0.34);
  gain.gain.exponentialRampToValueAtTime(0.0001, now + duration);
  oscillator.connect(gain);
  gain.connect(context.destination);
  oscillator.start(now);
  oscillator.stop(now + duration + 0.02);
}

function sendReminder() {
  if (state.reminders.sound) {
    playReminderSound(0, 920);
    playReminderSound(0.62, 680);
    playReminderSound(1.24, 920);
    playReminderSound(1.86, 1080);
  }
  if (state.reminders.vibration && "vibrate" in navigator) {
    navigator.vibrate([260, 120, 260]);
  }
  if (state.reminders.notification && "Notification" in window && Notification.permission === "granted") {
    const options = {
      body: "看向 6 米外，眨眨眼，保持 20 秒。",
      icon: "assets/icon-192.png",
      badge: "assets/icon-192.png"
    };
    if ("serviceWorker" in navigator) {
      navigator.serviceWorker.ready
        .then((registration) => registration.showNotification("该休息眼睛了", options))
        .catch(() => new Notification("该休息眼睛了", options));
    } else {
      new Notification("该休息眼睛了", options);
    }
  }
}

function getBridgeBases() {
  const bases = [];
  if (location.protocol === "http:" || location.protocol === "https:") {
    bases.push(`${location.origin}/api`);
  }
  bases.push("http://127.0.0.1:17891/api");
  return [...new Set(bases)];
}

async function fetchBridge(base, path, options = {}, timeout = 900) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeout);
  try {
    return await fetch(`${base}${path}`, {
      ...options,
      signal: controller.signal,
      headers: {
        "content-type": "application/json",
        ...(options.headers || {})
      }
    });
  } finally {
    clearTimeout(timer);
  }
}

function renderNativeControls(connected = Boolean(nativeBridgeBase)) {
  nativeActionButtons.forEach((button) => {
    button.classList.toggle("active", button.dataset.nativeAction === state.native.action);
  });
  nativeToggle.classList.toggle("active", Boolean(state.native.enabled));
  nativeToggle.textContent = state.native.enabled ? "开" : "关";
  nativeToggle.setAttribute("aria-pressed", String(Boolean(state.native.enabled)));
  if (!state.native.enabled) {
    nativeStatus.textContent = connected
      ? "本机桥接已就绪；开启后到点可调用电脑强提醒。"
      : "未连接本机桥接服务，到点时使用网页内提醒。";
    return;
  }
  nativeStatus.textContent = connected
    ? `已连接本机桥接；开始计时后，本机程序会准时执行${state.native.action === "lock" ? "锁屏" : state.native.action === "screensaver" ? "屏保" : "全屏遮罩"}。`
    : "已开启电脑强提醒，但还没检测到本机桥接服务。";
}

async function detectNativeBridge() {
  for (const base of getBridgeBases()) {
    try {
      const response = await fetchBridge(base, "/status", { method: "GET" });
      if (!response.ok) continue;
      const data = await response.json();
      if (data?.ok) {
        nativeBridgeBase = base;
        renderNativeControls(true);
        return true;
      }
    } catch {
      // Try the next possible bridge address.
    }
  }
  nativeBridgeBase = "";
  renderNativeControls(false);
  return false;
}

async function invokeNativeRest(isTest = false) {
  if (!state.native.enabled) return false;
  const connected = nativeBridgeBase ? true : await detectNativeBridge();
  if (!connected) {
    reminderStatus.textContent = "没有连上本机桥接服务，已改用网页内提醒。";
    return false;
  }
  if (isTest && state.native.action === "lock") {
    const ok = window.confirm("测试锁屏会立即锁定电脑。是否继续？");
    if (!ok) return true;
  }
  try {
    const response = await fetchBridge(nativeBridgeBase, "/rest", {
      method: "POST",
      body: JSON.stringify({
        action: state.native.action,
        seconds: 20,
        test: isTest
      })
    }, 1600);
    if (response.ok) {
      reminderStatus.textContent = "电脑强提醒已触发。";
      return true;
    }
  } catch {
    nativeBridgeBase = "";
  }
  reminderStatus.textContent = "电脑强提醒暂时不可用，已改用网页内提醒。";
  renderNativeControls(false);
  return false;
}

async function scheduleNativeRest(delaySeconds) {
  nativeTimerScheduled = false;
  nativeScheduleDeadline = 0;
  if (!state.native.enabled) return false;
  const connected = nativeBridgeBase ? true : await detectNativeBridge();
  if (!connected) {
    reminderStatus.textContent = "没有连上本机桥接服务，本次计时只能使用网页内提醒。";
    return false;
  }
  try {
    const response = await fetchBridge(nativeBridgeBase, "/schedule", {
      method: "POST",
      body: JSON.stringify({
        action: state.native.action,
        delaySeconds,
        restSeconds: 20
      })
    }, 1600);
    if (response.ok) {
      nativeTimerScheduled = true;
      nativeScheduleDeadline = Date.now() + delaySeconds * 1000;
      reminderStatus.textContent = "电脑强提醒已交给本机程序计时，切到其他窗口也会准时触发。";
      return true;
    }
  } catch {
    nativeBridgeBase = "";
  }
  reminderStatus.textContent = "本机计时任务创建失败，本次计时只能使用网页内提醒。";
  renderNativeControls(false);
  return false;
}

async function cancelNativeSchedule() {
  if (!nativeTimerScheduled && !nativeBridgeBase) return;
  nativeTimerScheduled = false;
  nativeScheduleDeadline = 0;
  if (!nativeBridgeBase) return;
  try {
    await fetchBridge(nativeBridgeBase, "/cancel", { method: "POST" }, 900);
  } catch {
    nativeBridgeBase = "";
    renderNativeControls(false);
  }
}

async function triggerBreak(isTest = false) {
  const handledByNative = await invokeNativeRest(isTest);
  if (!handledByNative) {
    startBreak();
  }
}

function startReminderLoop() {
  clearInterval(reminderLoopId);
  if (!state.reminders.sound) return;
  reminderLoopId = setInterval(() => {
    if (!breakDeadline) {
      clearInterval(reminderLoopId);
      reminderLoopId = null;
      return;
    }
    playReminderSound(0, 920);
    playReminderSound(0.62, 680);
    playReminderSound(1.24, 1080);
  }, 4000);
}

async function startTimer() {
  if (isRunning) {
    tickTimer();
    stopTimer();
    return;
  }
  await prepareWebReminder();
  const plannedSeconds = remainingSeconds;
  if (state.native.enabled) {
    startPause.disabled = true;
    reminderStatus.textContent = "正在把本次倒计时交给本机桥接程序...";
    const scheduled = await scheduleNativeRest(plannedSeconds);
    startPause.disabled = false;
    if (!scheduled) {
      nativeTimerScheduled = false;
      nativeScheduleDeadline = 0;
      reminderStatus.textContent = "没有连上电脑强提醒，本次已自动改用网页提示音、系统通知和页面提醒。";
      window.alert("没有连上电脑强提醒，本次将继续使用普通网页提醒。倒计时结束时会播放提示音；如已授权系统通知，切换到其他页面后也会收到通知。");
    }
  }
  isRunning = true;
  timerDeadline = Date.now() + plannedSeconds * 1000;
  saveTimerRuntime();
  startPause.textContent = "暂停";
  tickTimer();
  timerId = setInterval(tickTimer, 250);
}

function reset() {
  clearInterval(timerId);
  timerId = null;
  isRunning = false;
  timerDeadline = 0;
  cancelNativeSchedule();
  saveTimerRuntime();
  remainingSeconds = totalSeconds;
  startPause.textContent = "开始";
  renderTimer();
}

function startBreak() {
  clearInterval(breakId);
  breakDeadline = Date.now() + 20 * 1000;
  document.title = "该休息眼睛了";
  if (typeof breakPanel.showModal === "function" && !breakPanel.open) {
    breakPanel.showModal();
  } else {
    breakPanel.setAttribute("open", "");
  }
  skipBreak.focus();
  startReminderLoop();
  tickBreak();
  breakId = setInterval(tickBreak, 250);
}

function endBreak() {
  clearInterval(breakId);
  clearInterval(reminderLoopId);
  breakId = null;
  reminderLoopId = null;
  breakDeadline = 0;
  document.title = defaultTitle;
  if (typeof breakPanel.close === "function" && breakPanel.open) {
    breakPanel.close();
  } else {
    breakPanel.removeAttribute("open");
  }
}

function tickBreak() {
  if (!breakDeadline) return;
  const left = Math.max(0, Math.ceil((breakDeadline - Date.now()) / 1000));
  breakLeft.textContent = left;
  if (left <= 0) endBreak();
}

modeButtons.forEach((button) => {
  button.addEventListener("click", () => {
    modeButtons.forEach((item) => item.classList.remove("active"));
    button.classList.add("active");
    totalSeconds = Number(button.dataset.minutes) * 60;
    remainingSeconds = totalSeconds;
    timerTitle.textContent = button.dataset.title;
    timerHint.textContent = button.dataset.hint;
    reset();
  });
});

function restoreTimerRuntime() {
  const saved = JSON.parse(localStorage.getItem(runtimeKey) || "null");
  if (!saved || saved.date !== todayKey()) {
    localStorage.removeItem(runtimeKey);
    return;
  }
  totalSeconds = Number(saved.totalSeconds) || totalSeconds;
  const savedMode = [...modeButtons].find((button) => Number(button.dataset.minutes) * 60 === totalSeconds);
  if (savedMode) {
    modeButtons.forEach((item) => item.classList.remove("active"));
    savedMode.classList.add("active");
    timerTitle.textContent = savedMode.dataset.title;
    timerHint.textContent = savedMode.dataset.hint;
  }
  timerDeadline = Number(saved.deadline) || 0;
  remainingSeconds = Math.max(0, Math.ceil((timerDeadline - Date.now()) / 1000));
  if (remainingSeconds <= 0) {
    isRunning = true;
    completeSession();
    return;
  }
  isRunning = true;
  startPause.textContent = "暂停";
  timerId = setInterval(tickTimer, 250);
}

document.querySelectorAll("[data-check]").forEach((item) => {
  item.addEventListener("change", () => {
    state.checks[item.dataset.check] = item.checked;
    save();
    updateStats();
  });
});

document.querySelectorAll(".food").forEach((item) => {
  item.addEventListener("click", () => {
    state.foods[item.dataset.food] = !state.foods[item.dataset.food];
    save();
    updateStats();
  });
});

document.querySelectorAll("[data-reminder]").forEach((item) => {
  item.addEventListener("click", async () => {
    const key = item.dataset.reminder;
    if (key === "notification" && !state.reminders.notification) {
      if (!("Notification" in window)) {
        reminderStatus.textContent = "当前浏览器不支持系统通知。";
        return;
      }
      const permission = await Notification.requestPermission();
      if (permission !== "granted") {
        reminderStatus.textContent = "系统通知未授权，仍可使用页面提示、声音或震动。";
        return;
      }
      reminderStatus.textContent = "系统通知已开启；切到别的页面时也能提醒。";
    }
    if (key === "vibration" && !("vibrate" in navigator)) {
      reminderStatus.textContent = "当前设备或浏览器不支持震动。";
      return;
    }
    state.reminders[key] = !state.reminders[key];
    save();
    updateStats();
  });
});

nativeActionButtons.forEach((button) => {
  button.addEventListener("click", () => {
    state.native.action = button.dataset.nativeAction;
    save();
    renderNativeControls();
    if (isRunning) {
      scheduleNativeRest(remainingSeconds);
    }
  });
});

nativeToggle.addEventListener("click", async () => {
  state.native.enabled = !state.native.enabled;
  save();
  renderNativeControls();
  if (state.native.enabled) {
    await detectNativeBridge();
    if (isRunning) {
      scheduleNativeRest(remainingSeconds);
    }
  } else {
    cancelNativeSchedule();
  }
});

examDone.addEventListener("click", () => {
  const date = new Date().toLocaleDateString("zh-CN");
  localStorage.setItem("eye-rest-last-exam", date);
  examStatus.textContent = `上次检查：${date}`;
});

startPause.addEventListener("click", startTimer);
resetTimer.addEventListener("click", reset);
skipBreak.addEventListener("click", endBreak);
breakPanel.addEventListener("cancel", (event) => {
  event.preventDefault();
});
testReminder.addEventListener("click", async () => {
  if (state.native.enabled) {
    const handledByNative = await invokeNativeRest(true);
    if (!handledByNative) {
      await prepareWebReminder();
      sendReminder();
      startBreak();
    }
    return;
  }
  await prepareWebReminder();
  sendReminder();
  startBreak();
});
document.addEventListener("visibilitychange", () => {
  tickTimer();
  tickBreak();
});
window.addEventListener("focus", () => {
  tickTimer();
  tickBreak();
});

window.addEventListener("beforeinstallprompt", (event) => {
  event.preventDefault();
  deferredInstallPrompt = event;
  installButton.hidden = false;
});

installButton.addEventListener("click", async () => {
  if (!deferredInstallPrompt) return;
  deferredInstallPrompt.prompt();
  await deferredInstallPrompt.userChoice;
  deferredInstallPrompt = null;
  installButton.hidden = true;
});

if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("sw.js");
}

examStatus.textContent = localStorage.getItem("eye-rest-last-exam")
  ? `上次检查：${localStorage.getItem("eye-rest-last-exam")}`
  : "还没有记录检查时间";
restoreTimerRuntime();
updateStats();
renderTimer();
detectNativeBridge();
