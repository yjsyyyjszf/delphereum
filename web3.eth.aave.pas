{******************************************************************************}
{                                                                              }
{                                  Delphereum                                  }
{                                                                              }
{             Copyright(c) 2020 Stefan van As <svanas@runbox.com>              }
{           Github Repository <https://github.com/svanas/delphereum>           }
{                                                                              }
{   Distributed under Creative Commons NonCommercial (aka CC BY-NC) license.   }
{                                                                              }
{            need tokens to test with?                                         }
{            1. make sure your wallet is set to the relevant testnet           }
{            2. go to https://testnet.aave.com/faucet                          }
{                                                                              }
{******************************************************************************}

unit web3.eth.aave;

{$I web3.inc}

interface

uses
  // Delphi
  System.TypInfo,
  // Velthuis' BigNumbers
  Velthuis.BigIntegers,
  // web3
  web3,
  web3.eth,
  web3.eth.contract,
  web3.eth.defi,
  web3.eth.erc20,
  web3.eth.types,
  web3.utils;

type
  EAave = class(EWeb3);

  // Global helper functions
  TAave = class(TLendingProtocol)
  protected
    class procedure UnderlyingAddress(
      client  : TWeb3;
      reserve : TReserve;
      callback: TAsyncAddress);
    class procedure Approve(
      client  : TWeb3;
      from    : TPrivateKey;
      reserve : TReserve;
      amount  : BigInteger;
      callback: TAsyncReceipt);
  public
    class function Name: string; override;
    class function Supports(
      chain  : TChain;
      reserve: TReserve): Boolean; override;
    class procedure APY(
      client  : TWeb3;
      reserve : TReserve;
      callback: TAsyncFloat); override;
    class procedure Deposit(
      client  : TWeb3;
      from    : TPrivateKey;
      reserve : TReserve;
      amount  : BigInteger;
      callback: TAsyncReceipt); override;
    class procedure Balance(
      client  : TWeb3;
      owner   : TAddress;
      reserve : TReserve;
      callback: TAsyncQuantity); override;
    class procedure Withdraw(
      client  : TWeb3;
      from    : TPrivateKey;
      reserve : TReserve;
      callback: TAsyncReceiptEx); override;
    class procedure WithdrawEx(
      client  : TWeb3;
      from    : TPrivateKey;
      reserve : TReserve;
      amount  : BigInteger;
      callback: TAsyncReceiptEx); override;
  end;

  // Global addresses register of the protocol. This contract is immutable and the address will never change.
  TAaveAddressesProvider = class(TCustomContract)
  public
    constructor Create(aClient: TWeb3); reintroduce;
    procedure GetLendingPool(callback: TAsyncAddress);
    procedure GetLendingPoolCore(callback: TAsyncAddress);
  end;

  // The LendingPool contract is the main contract of the Aave protocol.
  TAaveLendingPool = class(TCustomContract)
  protected
    procedure GetReserveData(reserve: TReserve; callback: TAsyncTuple);
  public
    procedure Deposit(
      from    : TPrivateKey;
      reserve : TReserve;
      amount  : BigInteger;
      callback: TAsyncReceipt);
    procedure LiquidityRate(reserve: TReserve; callback: TAsyncQuantity);
    procedure aTokenAddress(reserve: TReserve; callback: TAsyncAddress);
  end;

  // aTokens are interest-bearing derivative tokens that are minted and burned
  // upon deposit (called from LendingPool) and redeem (called from the aToken contract).
  // If you are developing on a testnet and require tokens, go to
  // https://testnet.aave.com/faucet, making sure that your wallet is set to the relevant testnet.
  TaToken = class(TERC20)
  public
    procedure Redeem(from: TPrivateKey; amount: BigInteger; callback: TAsyncReceipt);
  end;

// For internal calculations and to reduce the impact of rounding errors, the
// Aave protocol uses the concept of Ray Math. A Ray is a unit with 27 decimals
// of precision. All the rates (liquidity/borrow/utilisation rates) as well as
// the cumulative indexes and the aTokens exchange rates are expressed in Ray.
const
  RAY = 1e27;

implementation

{ TAave }

const
  UNDERLYING_ADDRESS: array[TReserve] of array[TChain] of TAddress = (
    ( // DAI
      '0x6b175474e89094c44da98b954eedeac495271d0f',  // Mainnet
      '0xf80A32A835F79D7787E8a8ee5721D0fEaFd78108',  // Ropsten
      '',                                            // Rinkeby
      '',                                            // Goerli
      '',                                            // RSK_main_net
      '',                                            // RSK_test_net
      '0xFf795577d9AC8bD7D90Ee22b6C1703490b6512FD',  // Kovan
      '0x6b175474e89094c44da98b954eedeac495271d0f'), // Ganache
    ( // USDC
      '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48',  // Mainnet
      '0x851dEf71f0e6A903375C1e536Bd9ff1684BAD802',  // Ropsten
      '',                                            // Rinkeby
      '',                                            // Goerli
      '',                                            // RSK_main_net
      '',                                            // RSK_test_net
      '0xe22da380ee6B445bb8273C81944ADEB6E8450422',  // Kovan
      '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48'), // Ganache
    ( // USDT
      '0xdac17f958d2ee523a2206206994597c13d831ec7',  // Mainnet
      '0xB404c51BBC10dcBE948077F18a4B8E553D160084',  // Ropsten
      '',                                            // Rinkeby
      '',                                            // Goerli
      '',                                            // RSK_main_net
      '',                                            // RSK_test_net
      '0x13512979ADE267AB5100878E2e0f485B568328a4',  // Kovan
      '0xdac17f958d2ee523a2206206994597c13d831ec7')  // Ganache
  );

// Returns the ERC-20 contract address of the underlying asset.
class procedure TAave.UnderlyingAddress(client: TWeb3; reserve: TReserve; callback: TAsyncAddress);
var
  addr: TAddress;
begin
  addr := UNDERLYING_ADDRESS[reserve][client.Chain];
  if addr <> '' then
    callback(addr, nil)
  else
    callback('',
      TError.Create('%s is not supported on %s', [
        GetEnumName(TypeInfo(TReserve), Ord(reserve)),
        GetEnumName(TypeInfo(TChain), Ord(client.Chain))
      ])
    );
end;

// Approve the LendingPoolCore contract to move your asset.
class procedure TAave.Approve(
  client  : TWeb3;
  from    : TPrivateKey;
  reserve : TReserve;
  amount  : BigInteger;
  callback: TAsyncReceipt);
var
  aap  : TAaveAddressesProvider;
  erc20: TERC20;
begin
  aap := TAaveAddressesProvider.Create(client);
  if Assigned(aap) then
  try
    aap.GetLendingPoolCore(procedure(core: TAddress; err: IError)
    begin
      if Assigned(err) then
        callback(nil, err)
      else
        UnderlyingAddress(client, reserve, procedure(addr: TAddress; err: IError)
        begin
          if Assigned(err) then
            callback(nil, err)
          else
          begin
            erc20 := TERC20.Create(client, addr);
            if Assigned(erc20) then
            begin
              erc20.ApproveEx(from, core, amount, procedure(rcpt: ITxReceipt; err: IError)
              begin
                try
                  callback(rcpt, err);
                finally
                  erc20.Free;
                end;
              end);
            end;
          end;
        end);
    end);
  finally
    aap.Free;
  end;
end;

class function TAave.Name: string;
begin
  Result := 'Aave';
end;

class function TAave.Supports(chain: TChain; reserve: TReserve): Boolean;
begin
  Result := chain in [Mainnet, Ganache, Ropsten, Kovan];
end;

// Returns the annual yield as a percentage with 4 decimals.
class procedure TAave.APY(client: TWeb3; reserve: TReserve; callback: TAsyncFloat);
var
  aap : TAaveAddressesProvider;
  pool: TAaveLendingPool;
begin
  aap := TAaveAddressesProvider.Create(client);
  if Assigned(aap) then
  try
    aap.GetLendingPool(procedure(addr: TAddress; err: IError)
    begin
      if Assigned(err) then
        callback(0, err)
      else
      begin
        pool := TAaveLendingPool.Create(client, addr);
        if Assigned(pool) then
        try
          pool.LiquidityRate(reserve, procedure(qty: BigInteger; err: IError)
          begin
            if Assigned(err) then
              callback(0, err)
            else
              callback(BigInteger.Divide(qty, BigInteger.Create(1e21)).AsInt64 / 1e4, nil);
          end);
        finally
          pool.Free;
        end;
      end;
    end);
  finally
    aap.Free;
  end;
end;

// Global helper function that deposits an underlying asset into the reserve.
class procedure TAave.Deposit(
  client  : TWeb3;
  from    : TPrivateKey;
  reserve : TReserve;
  amount  : BigInteger;
  callback: TAsyncReceipt);
var
  aap : TAaveAddressesProvider;
  pool: TAaveLendingPool;
begin
  // Before supplying an asset, we must first approve the LendingPoolCore contract.
  Approve(client, from, reserve, amount, procedure(rcpt: ITxReceipt; err: IError)
  begin
    if Assigned(err) then
      callback(nil, err)
    else
    begin
      aap := TAaveAddressesProvider.Create(client);
      if Assigned(aap) then
      try
        aap.GetLendingPool(procedure(addr: TAddress; err: IError)
        begin
          if Assigned(err) then
            callback(nil, err)
          else
          begin
            pool := TAaveLendingPool.Create(client, addr);
            if Assigned(pool) then
            try
              pool.Deposit(from, reserve, amount, callback);
            finally
              pool.Free;
            end;
          end;
        end);
      finally
        aap.Free;
      end;
    end;
  end);
end;

// Returns how much underlying assets you are entitled to.
class procedure TAave.Balance(
  client  : TWeb3;
  owner   : TAddress;
  reserve : TReserve;
  callback: TAsyncQuantity);
var
  aAp   : TAaveAddressesProvider;
  aPool : TAaveLendingPool;
  aToken: TaToken;
begin
  aAp := TAaveAddressesProvider.Create(client);
  if Assigned(aAp) then
  try
    aAp.GetLendingPool(procedure(addr: TAddress; err: IError)
    begin
      if Assigned(err) then
        callback(0, err)
      else
      begin
        aPool := TAaveLendingPool.Create(client, addr);
        if Assigned(aPool) then
        try
          aPool.aTokenAddress(reserve, procedure(addr: TAddress; err: IError)
          begin
            if Assigned(err) then
              callback(0, err)
            else
            begin
              aToken := TaToken.Create(client, addr);
              if Assigned(aToken) then
              try
                aToken.BalanceOf(owner, callback);
              finally
                aToken.Free;
              end;
            end;
          end);
        finally
          aPool.Free;
        end;
      end;
    end);
  finally
    aAp.Free;
  end;
end;

// Global helper function that redeems your balance of aTokens for the underlying asset.
class procedure TAave.Withdraw(
  client  : TWeb3;
  from    : TPrivateKey;
  reserve : TReserve;
  callback: TAsyncReceiptEx);
begin
  Balance(client, from.Address, reserve, procedure(amount: BigInteger; err: IError)
  begin
    if Assigned(err) then
      callback(nil, 0, err)
    else
      WithdrawEx(client, from, reserve, amount, callback);
  end);
end;

class procedure TAave.WithdrawEx(
  client  : TWeb3;
  from    : TPrivateKey;
  reserve : TReserve;
  amount  : BigInteger;
  callback: TAsyncReceiptEx);
var
  aAp   : TAaveAddressesProvider;
  aPool : TAaveLendingPool;
  aToken: TaToken;
begin
  aAp := TAaveAddressesProvider.Create(client);
  if Assigned(aAp) then
  try
    aAp.GetLendingPool(procedure(addr: TAddress; err: IError)
    begin
      if Assigned(err) then
        callback(nil, 0, err)
      else
      begin
        aPool := TAaveLendingPool.Create(client, addr);
        if Assigned(aPool) then
        try
          aPool.aTokenAddress(reserve, procedure(addr: TAddress; err: IError)
          begin
            if Assigned(err) then
              callback(nil, 0, err)
            else
            begin
              aToken := TaToken.Create(client, addr);
              if Assigned(aToken) then
              try
                if Assigned(err) then
                  callback(nil, 0, err)
                else
                  aToken.Redeem(from, amount, procedure(rcpt: ITxReceipt; err: IError)
                  begin
                    if Assigned(err) then
                      callback(nil, 0, err)
                    else
                      callback(rcpt, amount, nil);
                  end);
              finally
                aToken.Free;
              end;
            end;
          end);
        finally
          aPool.Free;
        end;
      end;
    end);
  finally
    aAp.Free;
  end;
end;

{ TAaveAddressesProvider }

constructor TAaveAddressesProvider.Create(aClient: TWeb3);
begin
  // https://docs.aave.com/developers/developing-on-aave/deployed-contract-instances
  case aClient.Chain of
    Mainnet, Ganache:
      inherited Create(aClient, '0x24a42fD28C976A61Df5D00D0599C34c4f90748c8');
    Ropsten:
      inherited Create(aClient, '0x1c8756FD2B28e9426CDBDcC7E3c4d64fa9A54728');
    Rinkeby:
      raise EAave.Create('Aave is not deployed on Rinkeby');
    Goerli:
      raise EAave.Create('Aave is not deployed on Goerli');
    Kovan:
      inherited Create(aClient, '0x506B0B2CF20FAA8f38a4E2B524EE43e1f4458Cc5');
  end;
end;

// Fetch the address of the latest implementation of the LendingPool contract.
// Note: this is the address then you will need to create TAaveLendingPool with.
procedure TAaveAddressesProvider.GetLendingPool(callback: TAsyncAddress);
begin
  web3.eth.call(Client, Contract, 'getLendingPool()', [], procedure(const hex: string; err: IError)
  begin
    if Assigned(err) then
      callback('', err)
    else
      callback(TAddress.New(hex), nil);
  end);
end;

// Fetch the address of the latest implementation of the LendingPoolCore contract.
// Note: this is the address that you should approve() of `amount` before you deposit into the LendingPool.
procedure TAaveAddressesProvider.GetLendingPoolCore(callback: TAsyncAddress);
begin
  web3.eth.call(Client, Contract, 'getLendingPoolCore()', [], procedure(const hex: string; err: IError)
  begin
    if Assigned(err) then
      callback('', err)
    else
      callback(TAddress.New(hex), nil);
  end);
end;

{ TAaveLendingPool }

// Deposits the underlying asset into the reserve. A corresponding amount of the overlying asset (aTokens) is minted.
// The amount of aTokens received depends on the corresponding aToken exchange rate.
// When depositing an ERC-20 token, the LendingPoolCore contract (which is different from the LendingPool contract)
// will need to have the relevant allowance via approve() of `amount` for the underlying ERC20 of the `reserve` asset
// you are depositing.
procedure TAaveLendingPool.Deposit(
  from    : TPrivateKey;
  reserve : TReserve;
  amount  : BigInteger;
  callback: TAsyncReceipt);
begin
  TAave.UnderlyingAddress(Client, reserve, procedure(addr: TAddress; err: IError)
  begin
    if Assigned(err) then
      callback(nil, err)
    else
      web3.eth.write(
        Client, from, Contract,
        'deposit(address,uint256,uint16)',
        [addr, web3.utils.toHex(amount), 42], callback);
  end);
end;

// https://docs.aave.com/developers/developing-on-aave/the-protocol/lendingpool#getreservedata
procedure TAaveLendingPool.GetReserveData(reserve: TReserve; callback: TAsyncTuple);
begin
  TAave.UnderlyingAddress(Client, reserve, procedure(addr: TAddress; err: IError)
  begin
    if Assigned(err) then
      callback(nil, err)
    else
      web3.eth.call(Client, Contract, 'getReserveData(address)', [addr], callback);
  end);
end;

// Returns current yearly interest (APY) earned by the depositors, in Ray units.
procedure TAaveLendingPool.LiquidityRate(reserve: TReserve; callback: TAsyncQuantity);
begin
  GetReserveData(reserve, procedure(tup: TTuple; err: IError)
  begin
    if Assigned(err) then
      callback(BigInteger.Zero, err)
    else
      callback(tup[4].toBigInt, nil);
  end);
end;

// Returns aToken contract address for the specified reserve.
// Note: this is the address then you will need to create TaToken with.
procedure TAaveLendingPool.aTokenAddress(reserve: TReserve; callback: TAsyncAddress);
begin
  GetReserveData(reserve, procedure(tup: TTuple; err: IError)
  begin
    if Assigned(err) then
      callback('', err)
    else
      callback(TAddress.New(tup[11]), nil);
  end);
end;

{ TaToken }

// redeem an `amount` of aTokens for the underlying asset, burning the aTokens during the process.
procedure TaToken.Redeem(from: TPrivateKey; amount: BigInteger; callback: TAsyncReceipt);
begin
  web3.eth.write(
    Client, from, Contract,
    'redeem(uint256)', [web3.utils.toHex(amount)], callback);
end;

end.
