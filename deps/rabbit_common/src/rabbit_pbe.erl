%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2017 Pivotal Software, Inc.  All rights reserved.
%%

-module(rabbit_pbe).

-export([supported_ciphers/0, supported_hashes/0, default_cipher/0, default_hash/0, default_iterations/0]).
-export([encrypt_term/5, decrypt_term/5]).
-export([encrypt/5, decrypt/5]).

%% Supported ciphers and hashes

supported_ciphers() ->
    NotSupportedByUs = [aes_ctr, aes_ecb, des_ecb, blowfish_ecb, rc4, aes_gcm],
    SupportedByCrypto = proplists:get_value(ciphers, crypto:supports()),
    lists:filter(fun(Cipher) ->
        not lists:member(Cipher, NotSupportedByUs)
    end,
    SupportedByCrypto).

supported_hashes() ->
    NotSupportedByUs = [md4, ripemd160],
    SupportedByCrypto = proplists:get_value(hashs, crypto:supports()),
    lists:filter(fun(Hash) ->
        not lists:member(Hash, NotSupportedByUs)
    end,
    SupportedByCrypto).

%% Default encryption parameters (keep those in sync with rabbit.app.src)
default_cipher() ->
    aes_cbc256.

default_hash() ->
    sha512.

default_iterations() ->
    1000.

%% Encryption/decryption of arbitrary Erlang terms.

encrypt_term(Cipher, Hash, Iterations, PassPhrase, Term) ->
    encrypt(Cipher, Hash, Iterations, PassPhrase, term_to_binary(Term)).

decrypt_term(Cipher, Hash, Iterations, PassPhrase, Base64Binary) ->
    binary_to_term(decrypt(Cipher, Hash, Iterations, PassPhrase, Base64Binary)).

%% The cipher for encryption is from the list of supported ciphers.
%% The hash for generating the key from the passphrase is from the list
%% of supported hashes. See crypto:supports/0 to obtain both lists.
%% The key is generated by applying the hash N times with N >= 1.
%%
%% The encrypt/5 function returns a base64 binary and the decrypt/5
%% function accepts that same base64 binary.

-spec encrypt(crypto:block_cipher(), crypto:hash_algorithms(),
    pos_integer(), iodata(), binary()) -> binary().
encrypt(Cipher, Hash, Iterations, PassPhrase, ClearText) ->
    Salt = crypto:strong_rand_bytes(16),
    Ivec = crypto:strong_rand_bytes(iv_length(Cipher)),
    Key = make_key(Cipher, Hash, Iterations, PassPhrase, Salt),
    Binary = crypto:block_encrypt(Cipher, Key, Ivec, pad(Cipher, ClearText)),
    base64:encode(<< Salt/binary, Ivec/binary, Binary/binary >>).

-spec decrypt(crypto:block_cipher(), crypto:hash_algorithms(),
    pos_integer(), iodata(), binary()) -> binary().
decrypt(Cipher, Hash, Iterations, PassPhrase, Base64Binary) ->
    IvLength = iv_length(Cipher),
    << Salt:16/binary, Ivec:IvLength/binary, Binary/bits >> = base64:decode(Base64Binary),
    Key = make_key(Cipher, Hash, Iterations, PassPhrase, Salt),
    unpad(crypto:block_decrypt(Cipher, Key, Ivec, Binary)).

%% Generate a key from a passphrase.

make_key(Cipher, Hash, Iterations, PassPhrase, Salt) ->
    Key = pbdkdf2(PassPhrase, Salt, Iterations, key_length(Cipher),
        fun crypto:hmac/4, Hash, hash_length(Hash)),
    if
        Cipher =:= des3_cbc; Cipher =:= des3_cbf; Cipher =:= des3_cfb; Cipher =:= des_ede3 ->
            << A:8/binary, B:8/binary, C:8/binary >> = Key,
            [A, B, C];
        true ->
            Key
    end.

%% Functions to pad/unpad input to a multiplier of block size.

pad(Cipher, Data) ->
    BlockSize = block_size(Cipher),
    N = BlockSize - (byte_size(Data) rem BlockSize),
    Pad = list_to_binary(lists:duplicate(N, N)),
    <<Data/binary, Pad/binary>>.

unpad(Data) ->
    N = binary:last(Data),
    binary:part(Data, 0, byte_size(Data) - N).

%% These functions are necessary because the current Erlang crypto interface
%% is lacking interfaces to the following OpenSSL functions:
%%
%% * int EVP_MD_size(const EVP_MD *md);
%% * int EVP_CIPHER_iv_length(const EVP_CIPHER *e);
%% * int EVP_CIPHER_key_length(const EVP_CIPHER *e);
%% * int EVP_CIPHER_block_size(const EVP_CIPHER *e);

hash_length(md4) -> 16;
hash_length(md5) -> 16;
hash_length(sha) -> 20;
hash_length(sha224) -> 28;
hash_length(sha256) -> 32;
hash_length(sha384) -> 48;
hash_length(sha512) -> 64.

iv_length(des_cbc) -> 8;
iv_length(des_cfb) -> 8;
iv_length(des3_cbc) -> 8;
iv_length(des3_cbf) -> 8;
iv_length(des3_cfb) -> 8;
iv_length(des_ede3) -> 8;
iv_length(blowfish_cbc) -> 8;
iv_length(blowfish_cfb64) -> 8;
iv_length(blowfish_ofb64) -> 8;
iv_length(rc2_cbc) -> 8;
iv_length(aes_cbc) -> 16;
iv_length(aes_cbc128) -> 16;
iv_length(aes_cfb8) -> 16;
iv_length(aes_cfb128) -> 16;
iv_length(aes_cbc256) -> 16;
iv_length(aes_ige256) -> 32.

key_length(des_cbc) -> 8;
key_length(des_cfb) -> 8;
key_length(des3_cbc) -> 24;
key_length(des3_cbf) -> 24;
key_length(des3_cfb) -> 24;
key_length(des_ede3) -> 24;
key_length(blowfish_cbc) -> 16;
key_length(blowfish_cfb64) -> 16;
key_length(blowfish_ofb64) -> 16;
key_length(rc2_cbc) -> 16;
key_length(aes_cbc) -> 16;
key_length(aes_cbc128) -> 16;
key_length(aes_cfb8) -> 16;
key_length(aes_cfb128) -> 16;
key_length(aes_cbc256) -> 32;
key_length(aes_ige256) -> 16.

block_size(aes_cbc256) -> 32;
block_size(aes_cbc128) -> 32;
block_size(aes_ige256) -> 32;
block_size(aes_cbc) -> 32;
block_size(_) -> 8.

%% The following was taken from OTP's lib/public_key/src/pubkey_pbe.erl
%%
%% This is an undocumented interface to password-based encryption algorithms.
%% These functions have been copied here to stay compatible with R16B03.

%%--------------------------------------------------------------------
-spec pbdkdf2(string(), iodata(), integer(), integer(), fun(), atom(), integer())
	     -> binary().
%%
%% Description: Implements password based decryption key derive function 2.
%% Exported mainly for testing purposes.
%%--------------------------------------------------------------------
pbdkdf2(Password, Salt, Count, DerivedKeyLen, Prf, PrfHash, PrfOutputLen)->
    NumBlocks = ceiling(DerivedKeyLen / PrfOutputLen),
    NumLastBlockOctets = DerivedKeyLen - (NumBlocks - 1) * PrfOutputLen ,
    blocks(NumBlocks, NumLastBlockOctets, 1, Password, Salt,
	   Count, Prf, PrfHash, PrfOutputLen, <<>>).

blocks(1, N, Index, Password, Salt, Count, Prf, PrfHash, PrfLen, Acc) ->
    <<XorSum:N/binary, _/binary>> = xor_sum(Password, Salt, Count, Index, Prf, PrfHash, PrfLen),
    <<Acc/binary, XorSum/binary>>;
blocks(NumBlocks, N, Index, Password, Salt, Count, Prf, PrfHash, PrfLen, Acc) ->
    XorSum = xor_sum(Password, Salt, Count, Index, Prf, PrfHash, PrfLen),
    blocks(NumBlocks -1, N, Index +1, Password, Salt, Count, Prf, PrfHash,
	   PrfLen, <<Acc/binary, XorSum/binary>>).

xor_sum(Password, Salt, Count, Index, Prf, PrfHash, PrfLen) ->
    Result = Prf(PrfHash, Password, [Salt,<<Index:32/unsigned-big-integer>>], PrfLen),
    do_xor_sum(Prf, PrfHash, PrfLen, Result, Password, Count-1, Result).

do_xor_sum(_, _, _, _, _, 0, Acc) ->
    Acc;
do_xor_sum(Prf, PrfHash, PrfLen, Prev, Password, Count, Acc) ->
    Result = Prf(PrfHash, Password, Prev, PrfLen),
    do_xor_sum(Prf, PrfHash, PrfLen, Result, Password, Count-1, crypto:exor(Acc, Result)).

ceiling(Float) ->
    erlang:round(Float + 0.5).
