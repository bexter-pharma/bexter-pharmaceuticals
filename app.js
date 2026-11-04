import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cfg = window.BEXTER_CONFIG || {};
const loginView = document.querySelector("#loginView");
const dashboardView = document.querySelector("#dashboardView");
const notice = document.querySelector("#setupNotice");
const msg = document.querySelector("#loginMessage");
const logout = document.querySelector("#logoutBtn");

function say(t, e = false) {
  msg.textContent = t;
  msg.className = e ? "message error" : "message";
}

function showLogin() {
  loginView.classList.remove("hidden");
  dashboardView.classList.add("hidden");
  logout.classList.add("hidden");
}

function showDashboard(n) {
  document.querySelector("#adminName").textContent = n || "Admin";
  loginView.classList.add("hidden");
  dashboardView.classList.remove("hidden");
  logout.classList.remove("hidden");
}

const ready =
  cfg.SUPABASE_URL?.startsWith("https://") &&
  cfg.SUPABASE_PUBLISHABLE_KEY &&
  !cfg.SUPABASE_PUBLISHABLE_KEY.includes("PASTE_");

if (!ready) {
  say("config.js এখনো পূরণ করা হয়নি।", true);
} else {
  notice.classList.add("hidden");
  const supabase = createClient(
    cfg.SUPABASE_URL,
    cfg.SUPABASE_PUBLISHABLE_KEY
  );

  async function profile(user) {
    const { data, error } = await supabase
      .from("profiles")
      .select("full_name,role")
      .eq("id", user.id)
      .maybeSingle();

    if (error) throw error;

    if (!data || data.role !== "admin") {
      await supabase.auth.signOut();
      throw new Error("এই account-এর Admin permission নেই।");
    }

    showDashboard(data.full_name);
  }

  document.querySelector("#loginForm").addEventListener("submit", async ev => {
    ev.preventDefault();
    const btn = ev.currentTarget.querySelector("button");
    btn.disabled = true;
    say("Login যাচাই হচ্ছে...");

    try {
      const { data, error } = await supabase.auth.signInWithPassword({
        email: document.querySelector("#email").value.trim(),
        password: document.querySelector("#password").value
      });

      if (error) throw error;
      await profile(data.user);
    } catch (e) {
      say(e.message || "Login করা যায়নি।", true);
    } finally {
      btn.disabled = false;
    }
  });

  logout.addEventListener("click", async () => {
    await supabase.auth.signOut();
    showLogin();
    say("Logout সম্পন্ন হয়েছে।");
  });

  supabase.auth.getSession().then(async ({ data }) => {
    if (data.session?.user) {
      try {
        await profile(data.session.user);
      } catch (e) {
        showLogin();
        say(e.message, true);
      }
    }
  });
}

if ("serviceWorker" in navigator && location.protocol.startsWith("http")) {
  addEventListener("load", () => {
    navigator.serviceWorker.register("./sw.js").catch(console.error);
  });
}
