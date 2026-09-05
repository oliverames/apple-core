import test from 'node:test';
import assert from 'node:assert/strict';
import {handle, isProtectedPath, paidPurchase, signedLicense} from './worker.mjs';
const PRODUCT = 'H5iMAgmqjSc9_p61iSwApA==';
const key = ['AAAAAAAA', 'BBBBBBBB', 'CCCCCCCC', 'DDDDDDDD'].join('-');
const purchase = {product_id: PRODUCT, sale_id:'sale', price:1500};
const url = 'https://assets.amesvt.com/apple-core/Apple.Core-1.7.3.zip';

test('anonymous, forged and oversized credentials never reach storage', async () => {
  for (const credential of [null, 'forged', 'x'.repeat(16385)]) {
    let fetched = false;
    const result = await handle(new Request(url, {headers: credential ? {'X-Apple-Core-License':credential} : {}}), async () => { fetched=true; });
    assert.ok([402,403].includes(result.status));
    assert.equal(fetched,false);
  }
});
test('protected prefix detects encoded and repeated separators', () => {
  for (const path of ['/apple-core/a.zip','/%61pple-core/a.zip','//apple-core/a.zip','/%2561pple-core/a.zip','/%2fapple-core/a.zip']) assert.equal(isProtectedPath(path), true);
  assert.equal(isProtectedPath('/photography/photo.jpg'),false);
});
test('paid policy rejects test, unpaid, preorder, other product and refunded purchases', () => {
  assert.equal(paidPurchase({success:true,purchase}),true);
  for (const p of [{}, {...purchase,price:0}, {...purchase,test:true}, {...purchase,test:'false'}, {...purchase,is_preorder_authorization:true}, {...purchase,refunded:true}, {...purchase,product_id:'other'}]) assert.equal(paidPurchase({success:true,purchase:p}),false);
  assert.equal(paidPurchase({success:true,purchase:{...purchase,price:0,is_gift_receiver_purchase:true,gift_price:1500}}),true);
});
test('valid Gumroad download preserves range, strips credentials and disables cache', async () => {
  let calls=0;
  const result=await handle(new Request(url,{headers:{'X-Apple-Core-License':key,Range:'bytes=0-3'}}),async (request,init)=>{
    calls++;
    if(typeof request==='string') {
      assert.equal(new URLSearchParams(init.body).get('increment_uses_count'),'false');
      return Response.json({success:true,purchase});
    }
    assert.equal(request.headers.get('X-Apple-Core-License'),null);
    assert.equal(request.headers.get('Range'),'bytes=0-3');
    assert.equal(init.cf.cacheTtl,0);
    return new Response('test',{status:206});
  });
  assert.equal(calls,2); assert.equal(result.status,206);
  assert.equal(result.headers.get('Cache-Control'),'private, no-store');
});
test('invalid, outage and oversized Gumroad replies fail closed', async () => {
  for(const response of [Response.json({success:false},{status:404}),new Response('outage',{status:500}),new Response('x'.repeat(65537))]) {
    const result=await handle(new Request(url,{headers:{'X-Apple-Core-License':key}}),async()=>response);
    assert.ok([403,503].includes(result.status));
  }
});
test('signed license checks signature, product and expiration',async()=>{
  const pair=await crypto.subtle.generateKey('Ed25519',true,['sign','verify']);
  const pub=Buffer.from(await crypto.subtle.exportKey('raw',pair.publicKey)).toString('base64');
  async function envelope(document) {
    const payload=Buffer.from(JSON.stringify(document));
    const signature=Buffer.from(await crypto.subtle.sign('Ed25519',pair.privateKey,payload));
    return Buffer.from(['APPLE-CORE-LICENSE-1',payload.toString('base64'),signature.toString('base64')].join('\n')).toString('base64');
  }
  assert.equal(await signedLicense(await envelope({product:'apple-core',license_id:'owner'}),pub),true);
  assert.equal(await signedLicense(await envelope({product:'other',license_id:'owner'}),pub),false);
  assert.equal(await signedLicense(await envelope({product:'apple-core',license_id:'owner',expires_at:'2020-01-01T00:00:00Z'}),pub),false);
  assert.equal(await signedLicense(await envelope({product:'apple-core',license_id:'owner'})),false);
});
test('other assets pass through without a license',async()=>{
  const result=await handle(new Request('https://assets.amesvt.com/photos/image.jpg'),async()=>new Response('photo'));
  assert.equal(await result.text(),'photo');
});
