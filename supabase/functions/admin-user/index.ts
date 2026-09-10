import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

Deno.serve(async (req) => {
  try {
    const body = await req.json();
    const { email, password, full_name, username, role="store_user", store_id=null } = body;
    if (!email || !password) return new Response(JSON.stringify({error:"email/password required"}), {status:400});

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const anon = req.headers.get("Authorization") || "";
    const caller = createClient(supabaseUrl, Deno.env.get("SUPABASE_ANON_KEY") || "");
    const adminDb = createClient(supabaseUrl, serviceKey);

    const token = anon.replace(/^Bearer\s+/i,"");
    const { data:{user:callerUser} } = await caller.auth.getUser(token);
    if (!callerUser) return new Response(JSON.stringify({error:"Unauthorized"}),{status:401});

    const { data:callerProfile } = await adminDb.from("profiles").select("role").eq("id",callerUser.id).single();
    if (callerProfile?.role !== "admin") return new Response(JSON.stringify({error:"Admin only"}),{status:403});

    const { data, error } = await adminDb.auth.admin.createUser({email, password, email_confirm:true});
    if (error) throw error;
    const { error: pe } = await adminDb.from("profiles").insert({id:data.user.id,full_name,username,role,store_id,is_active:true});
    if (pe) throw pe;

    return new Response(JSON.stringify({user_id:data.user.id}),{headers:{"content-type":"application/json"}});
  } catch(e) {
    return new Response(JSON.stringify({error:String(e?.message||e)}),{status:500,headers:{"content-type":"application/json"}});
  }
});
