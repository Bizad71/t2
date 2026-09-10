import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
Deno.serve(async (req) => {
  try {
    const auth = req.headers.get('Authorization')
    if (!auth) return new Response(JSON.stringify({error:'Unauthorized'}),{status:401})
    const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {global:{headers:{Authorization:auth}}})
    const {data:{user}} = await supabase.auth.getUser(); if(!user) return new Response(JSON.stringify({error:'Unauthorized'}),{status:401})
    const {data:profile}=await supabase.from('profiles').select('role').eq('id',user.id).single(); if(profile?.role!=='admin') return new Response(JSON.stringify({error:'Admin required'}),{status:403})
    const body=await req.json(); const {email,password,full_name,username,store_id,role='store_user'}=body
    if(!email||!password||!store_id) throw new Error('email,password,store_id required')
    const admin=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
    const {data:created,error}=await admin.auth.admin.createUser({email,password,email_confirm:true})
    if(error) throw error
    const {error:pe}=await admin.from('profiles').upsert({id:created.user.id,full_name,username,store_id,role,is_active:true})
    if(pe){await admin.auth.admin.deleteUser(created.user.id);throw pe}
    return new Response(JSON.stringify({id:created.user.id}),{headers:{'content-type':'application/json'}})
  } catch(e){return new Response(JSON.stringify({error:String(e?.message||e)}),{status:400,headers:{'content-type':'application/json'}})}
})
