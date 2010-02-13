{-# LANGUAGE GeneralizedNewtypeDeriving, ScopedTypeVariables #-}
module Halfs.Inode
  (
    Inode(..)
  , InodeRef(..)
  , blockAddrToInodeRef
  , buildEmptyInodeEnc
  , drefInode
  , inodeKey
  , inodeRefToBlockAddr
  , nilInodeRef
  , readStream
  , writeStream
  -- * for testing
  , Cont(..)
  , ContRef(..)
  , bsDrop
  , bsTake
  , computeNumAddrs
  , computeNumInodeAddrsM
  , computeNumContAddrsM
  , decodeCont
  , decodeInode
  , minimalContSize
  , minimalInodeSize
  , minInodeBlocks
  , minContBlocks
  , safeToInt
  , truncSentinel
  )
 where

import Control.Exception
import Data.ByteString(ByteString)
import qualified Data.ByteString as BS
import Data.Char
import Data.List (genericDrop, genericTake, genericSplitAt)
import Data.Serialize 
import Data.Serialize.Get
import Data.Serialize.Put
import Data.Word

import Halfs.BlockMap (BlockMap)
import qualified Halfs.BlockMap as BM
import Halfs.Classes
import Halfs.Errors
import Halfs.Protection
import Halfs.Monad
import Halfs.Types
import Halfs.Utils

import System.Device.BlockDevice

-- import Debug.Trace

--import System.IO.Unsafe
dbug :: String -> a -> a
--dbug   = seq . unsafePerformIO . putStrLn
dbug _ = id
--dbug = trace


--------------------------------------------------------------------------------
-- Inode constructors, geometry calculation, and helper functions

type StreamIdx = (Word64, Word64, Word64)

newtype ContRef = CR { unCR :: Word64 } deriving (Eq, Show)
instance Serialize ContRef where
  put (CR x) = putWord64be x
  get        = CR `fmap` getWord64be

-- | Obtain a 64 bit "key" for an inode; useful for building maps etc.
-- For now, this is the same as inodeRefToBlockAddr, but clients should
-- be using this function rather than inodeRefToBlockAddr in case the
-- underlying inode representation changes.
inodeKey :: InodeRef -> Word64
inodeKey = inodeRefToBlockAddr

-- | Convert a disk block address into an Inode reference.
blockAddrToInodeRef :: Word64 -> InodeRef
blockAddrToInodeRef = IR

-- | Convert an inode reference into a block address
inodeRefToBlockAddr :: InodeRef -> Word64
inodeRefToBlockAddr (IR x) = x

-- | The nil Inode reference.  With the current Word64 representation and the
-- block layout assumptions, block 0 is the superblock, and thus an invalid
-- inode reference.
nilInodeRef :: InodeRef
nilInodeRef = IR 0

nilContRef :: ContRef
nilContRef = CR 0

-- | The sentinel byte written to partial blocks when doing truncating writes
truncSentinel :: Word8
truncSentinel = 0xBA

-- | The sentinel byte written to the padding region at the end of BlockCarriers
padSentinel :: Word8
padSentinel = 0xAD

-- | The size of the padding region at the end of BlockCarriers
bcPadSize :: Int
bcPadSize = 7

-- | The structure of an Inode. Pretty standard, except that we use the
-- continuation field to allow multiple runs of block addresses within the
-- file. We serialize Nothing as nilInodeRef, an invalid continuation.
--
-- We semi-arbitrarily state that an Inode must be capable of maintaining a
-- minimum of 50 block addresses, which gives us a minimum inode size of 512
-- bytes (in the IO monad variant, which uses the our Serialize instance for the
-- UTCTime when writing the createTime and modifyTime fields).
--
minInodeBlocks :: Word64
minInodeBlocks = 48

minContBlocks :: Word64
minContBlocks = 56

data (Eq t, Ord t, Serialize t) => Inode t = Inode
  { inoAddress       :: InodeRef        -- ^ block addr of this inode
  , inoParent        :: InodeRef        -- ^ block addr of parent directory inode:
                                        --   This is nilInodeRef for the root
                                        --   directory inode and for inodes in the
                                        --   continuation chain of other inodes.
  , inoContinuation  :: ContRef
  , inoFileSize      :: Word64
  , inoCreateTime    :: t
  , inoModifyTime    :: t
  , inoUser          :: UserID
  , inoGroup         :: GroupID
  , inoBlockCount    :: Word64       -- ^ current number of active blocks (equal
                                     -- to the number of (sequential) inode
                                     -- references held in the blocks list)

  , inoBlocks        :: [Word64]

  -- Fields below here are not persisted, and are populated via decodeInode

  , inoNumAddrs      :: Word64       -- ^ Maximum number of blocks addressable
                                     -- by this inode.  NB: Does not include any
                                     -- continuations, and is only used for
                                     -- convenience.
  }
  deriving (Show, Eq)

data Cont = Cont
  { inocAddress      :: ContRef
  , inocContinuation :: ContRef
  , inocBlockCount   :: Word64
  , inocBlocks       :: [Word64]
  , inocNumAddrs     :: Word64 -- transient
  }
  deriving (Show, Eq)

data (Eq t, Ord t, Serialize t) => BlockCarrier t = BC
  { bcRep           :: Either (Inode t) (Cont)
  , address         :: Word64
  , continuation    :: ContRef
  , setContinuation :: ContRef -> BlockCarrier t
  , blockCount      :: Word64
  , setBlockCount   :: Word64 -> BlockCarrier t
  , blockAddrs      :: [Word64]
  , setBlockAddrs   :: [Word64] -> BlockCarrier t
  , numAddrs        :: Word64
  }

inodeBC :: (Eq t, Ord t, Serialize t) => Inode t -> BlockCarrier t
inodeBC = newBC . Left

contBC :: (Eq t, Ord t, Serialize t) => Cont -> BlockCarrier t
contBC = newBC . Right

newBC :: (Eq t, Ord t, Serialize t) => Either (Inode t) (Cont) -> BlockCarrier t
newBC x@(Left ino) =
  BC
  { bcRep           = x
  , address         = inodeRefToBlockAddr $ inoAddress ino
  , continuation    = inoContinuation ino
  , setContinuation = \mc -> inodeBC $ ino{inoContinuation = mc}
  , blockCount      = inoBlockCount ino
  , setBlockCount   = \bc -> inodeBC $ ino{inoBlockCount = bc}
  , blockAddrs      = inoBlocks ino
  , setBlockAddrs   = \xs -> inodeBC $ ino{inoBlocks = xs}
  , numAddrs        = inoNumAddrs ino
  }
newBC x@(Right inoc) =
  BC
  { bcRep           = x
  , address         = unCR $ inocAddress inoc
  , continuation    = inocContinuation inoc
  , setContinuation = \mc -> contBC $ inoc{inocContinuation = mc}
  , blockCount      = inocBlockCount inoc
  , setBlockCount   = \bc -> contBC $ inoc{inocBlockCount = bc}
  , blockAddrs      = inocBlocks inoc
  , setBlockAddrs   = \xs -> contBC $ inoc{inocBlocks = xs}
  , numAddrs        = inocNumAddrs inoc
  }

instance (Ord t, Serialize t, Show t) => Show (BlockCarrier t) where
  show = either show show . bcRep

instance (Eq t, Ord t, Serialize t) => Serialize (BlockCarrier t) where
  put bc = do
    put (bcRep bc)
    replicateM_ bcPadSize $ putWord8 padSentinel
  get = do
    bc      <- newBC `fmap` get
    padding <- replicateM bcPadSize $ getWord8
    assert (all (== padSentinel) padding) $ return ()
    return bc

instance Serialize Cont where
  put c = do
    unless (numBlocks <= numAddrs') $
      fail $ "Corrupted Cont structure put: too many blocks"
    putByteString $ cmagic1
    put           $ inocAddress c
    put           $ inocContinuation c 
    putByteString $ cmagic2
    putWord64be   $ inocBlockCount c
    putByteString $ cmagic3
    forM_ blocks' put
    replicateM_ fillBlocks $ put nilInodeRef
    putByteString cmagic4
    where
      blocks'    = inocBlocks c
      numAddrs'  = safeToInt $ inocNumAddrs c
      numBlocks  = length blocks'
      fillBlocks = numAddrs' - numBlocks

  get = do
    checkMagic cmagic1
    addr <- get
    cont <- get
    checkMagic cmagic2 
    blkCnt <- getWord64be
    checkMagic cmagic3 
    remb <- fromIntegral `fmap` remaining
    let numBlockBytes      = remb - 8 -- account for trailing cmagic4
        (numBlocks, check) = numBlockBytes `divMod` refSize
    unless (check == fromIntegral bcPadSize) $
      -- Only trailing bytes for BlockCarrier padding (if any) should remain in
      -- the input stream
      fail "Cont: Incorrect number of bytes left for block list."
    unless (numBlocks >= minContBlocks) $
      fail "Cont: Not enough space left for minimum number of blocks."
    blks <- filter (/= 0) `fmap` replicateM (safeToInt numBlocks) get
    checkMagic cmagic4 
    let na = error $ "numAddrs has not been populated via Data.Serialize.get "
                  ++ "for Cont; did you forget to use the " 
                  ++ "Inode.decodeCont wrapper?"
    return Cont
           { inocAddress      = addr
           , inocContinuation = cont
           , inocBlockCount   = blkCnt
           , inocBlocks       = blks
           , inocNumAddrs     = na
           }
   where
    checkMagic x = do
      magic <- getBytes 8
      unless (magic == x) $ fail "Invalid Cont: magic number mismatch"

instance (Eq t, Ord t, Serialize t) => Serialize (Inode t) where
  put n = do
    unless (numBlocks <= numAddrs') $
      fail $ "Corrupted Inode structure put: too many blocks"
    putByteString magic1
    put $ inoAddress n
    put $ inoParent n
    put $ inoContinuation n
    putWord64be $ inoFileSize n
    put $ inoCreateTime n
    put $ inoModifyTime n
    putByteString magic2
    put $ inoUser n
    put $ inoGroup n
    putWord64be $ inoBlockCount n
    putByteString magic3
    forM_ blocks' put
    replicateM_ fillBlocks $ put nilInodeRef
    putByteString magic4
    where
      blocks'    = inoBlocks n
      numAddrs'  = safeToInt $ inoNumAddrs n
      numBlocks  = length blocks'
      fillBlocks = numAddrs' - numBlocks

  get = do
    checkMagic magic1
    addr <- get
    par  <- get
    cont <- get
    fsz  <- getWord64be
    ctm  <- get
    mtm  <- get
    unless (mtm >= ctm) $
      fail "Inode: Incoherent modified / creation times."
    checkMagic magic2
    usr  <- get
    grp  <- get
    blkCnt <- getWord64be
    checkMagic magic3
    remb <- fromIntegral `fmap` remaining
    let numBlockBytes      = remb - 8 -- account for trailing magic4
        (numBlocks, check) = numBlockBytes `divMod` refSize
    unless (check == fromIntegral bcPadSize) $
      -- Only trailing bytes for BlockCarrier padding (if any) should remain in
      -- the input stream
      fail "Inode: Incorrect number of bytes left for block list."
    unless (numBlocks >= minInodeBlocks) $
      fail "Inode: Not enough space left for minimum number of blocks."
    blks <- filter (/= 0) `fmap` replicateM (safeToInt numBlocks) get
    checkMagic magic4
    let na = error $ "numAddrs has not been populated via Data.Serialize.get "
                  ++ "for Inode; did you forget to use the " 
                  ++ "Inode.decodeInode wrapper?"
    return Inode
           { inoAddress      = addr
           , inoParent       = par
           , inoContinuation = cont
           , inoFileSize     = fsz
           , inoCreateTime   = ctm
           , inoModifyTime   = mtm
           , inoUser         = usr
           , inoGroup        = grp
           , inoBlockCount   = blkCnt
           , inoBlocks       = blks
           , inoNumAddrs     = na
           }
   where
    checkMagic x = do
      magic <- getBytes 8
      unless (magic == x) $ fail "Invalid Inode: magic number mismatch"

-- | Size of a minimal inode structure when serialized, in bytes.  This will
-- vary based on the space required for type t when serialized.  Note that
-- minimal inode structure always contains minInodeBlocks InodeRefs in
-- its blocks region.
--
-- You can check this value interactively in ghci by doing, e.g.
-- minimalInodeSize =<< (getTime :: IO UTCTime)
minimalInodeSize :: (Monad m, Ord t, Serialize t) => t -> m Word64
minimalInodeSize t = do
  return $ fromIntegral $ BS.length $ encode $
    emptyInode minInodeBlocks t t nilInodeRef nilInodeRef rootUser rootGroup
    `setBlockAddrs`
    replicate (safeToInt minInodeBlocks) 0

-- | The parameter to this function is not used except for type
-- unification with BlockCarrier t; it's safe to invoke this function
-- like (e.g.) minimalContSize (undefined :: UTCTime)
minimalContSize :: (Monad m, Ord t, Serialize t) => t -> m (Word64)
minimalContSize t = aux t >>= return . fst
  where
    aux :: (Serialize t, Ord t, Monad m) => t -> m (Word64, BlockCarrier t)
    aux _t = do
      let e = emptyCont minContBlocks nilContRef
              `setBlockAddrs`
              replicate (safeToInt minContBlocks) 0
      return (fromIntegral $ BS.length $ encode $ e,  e)

-- | Computes the number of block addresses storable by an inode/cont
computeNumAddrs :: Monad m => 
                   Word64 -- ^ block size, in bytes
                -> Word64 -- ^ minimum number of blocks for inode/cont
                -> Word64 -- ^ minimum inode/cont total size, in bytes
                -> m Word64
computeNumAddrs blkSz minBlocks minSize = do
  unless (minSize <= blkSz) $
    fail "computeNumAddrs: Block size too small to accomodate minimal inode"
  let
    -- # bytes required for the blocks region of the minimal inode
    padding       = minBlocks * refSize
    -- # bytes of the inode excluding the blocks region
    notBlocksSize = minSize - padding
    -- # bytes available for storing the blocks region
    blkSz'    = blkSz - notBlocksSize
  unless (0 == blkSz' `mod` refSize) $
    fail "computeNumAddrs: Inexplicably bad block size"
  return $ blkSz' `div` refSize

computeNumInodeAddrsM :: (Serialize t, Timed t m) =>
                         Word64 -> m Word64
computeNumInodeAddrsM blkSz =
  computeNumAddrs blkSz minInodeBlocks =<< minimalInodeSize =<< getTime

computeNumContAddrsM :: (Serialize t, Timed t m) =>
                        Word64 -> m Word64
computeNumContAddrsM blkSz = do
  minSize <- minimalContSize =<< getTime
  computeNumAddrs blkSz minContBlocks minSize

getSizes :: (Serialize t, Timed t m) =>
            Word64
         -> m ( Word64 -- #inode bytes
              , Word64 -- #cont bytes
              , Word64 -- #inode addrs
              , Word64 -- #cont addrs
              )
getSizes blkSz = do
  startContAddrs <- computeNumInodeAddrsM blkSz
  contAddrs      <- computeNumContAddrsM  blkSz
  return (startContAddrs * blkSz, contAddrs * blkSz, startContAddrs, contAddrs)

-- Builds and encodes an empty inode
buildEmptyInodeEnc :: (Serialize t, Timed t m) =>
                      BlockDevice m -- ^ The block device
                   -> InodeRef      -- ^ This inode's block address
                   -> InodeRef      -- ^ Parent's block address
                   -> UserID
                   -> GroupID
                   -> m ByteString
buildEmptyInodeEnc bd me mommy usr grp =
  liftM encode $ buildEmptyInode bd me mommy usr grp

buildEmptyInode :: (Serialize t, Timed t m) =>
                   BlockDevice m    -- ^ The block device
                -> InodeRef         -- ^ This inode's block address
                -> InodeRef         -- ^ Parent block's address
                -> UserID
                -> GroupID
                -> m (BlockCarrier t)
buildEmptyInode bd me mommy usr grp = do 
  now     <- getTime
  minSize <- minimalInodeSize =<< return now
  nAddrs  <- computeNumAddrs (bdBlockSize bd) minInodeBlocks minSize
  return $ emptyInode nAddrs now now me mommy usr grp

emptyInode :: (Ord t, Serialize t) => 
              Word64   -- ^ number of block addresses
           -> t        -- ^ creation time
           -> t        -- ^ last modify time
           -> InodeRef -- ^ block addr for this inode
           -> InodeRef -- ^ parent block address
           -> UserID  
           -> GroupID
           -> BlockCarrier t
emptyInode nAddrs createTm modTm me mommy usr grp =
  inodeBC Inode
  { inoAddress      = me
  , inoParent       = mommy
  , inoContinuation = nilContRef
  , inoFileSize     = 0
  , inoCreateTime   = createTm
  , inoModifyTime   = modTm
  , inoUser         = usr
  , inoGroup        = grp
  , inoNumAddrs     = nAddrs
  , inoBlockCount   = 0
  , inoBlocks       = []
  }

buildEmptyCont :: (Serialize t, Timed t m) =>
                  BlockDevice m -- ^ The block device
               -> ContRef       -- ^ This cont's block address
               -> m (BlockCarrier t)
buildEmptyCont bd me = do
  minSize <- minimalContSize =<< getTime
  nAddrs  <- computeNumAddrs (bdBlockSize bd) minContBlocks minSize
  return $ emptyCont nAddrs me

emptyCont :: (Ord t, Serialize t) =>
             Word64  -- ^ number of block addresses
          -> ContRef -- ^ block addr for this cont
          -> BlockCarrier t
emptyCont nAddrs me =
  contBC Cont
  { inocAddress      = me
  , inocContinuation = nilContRef
  , inocBlockCount   = 0
  , inocBlocks       = []
  , inocNumAddrs     = nAddrs
  }


--------------------------------------------------------------------------------
-- Inode stream functions

-- | Provides a stream over the bytes governed by a given Inode and its
-- continuations.
-- 
-- NB: This is a pretty primitive way to go about this, but it's probably
-- worthwhile to get something working before revisiting it.  In particular, if
-- this works well enough we might want to consider making this a little less
-- specific to the particulars of the way that the Inode tracks its block
-- addresses, counts, continuations, etc., and perhaps build enumerators for
-- inode/block/byte sequences over inodes.
readStream :: HalfsCapable b t r l m => 
              BlockDevice m                   -- ^ Block device
           -> InodeRef                        -- ^ Starting inode reference
           -> Word64                          -- ^ Starting stream (byte) offset
           -> Maybe Word64                    -- ^ Stream length (Nothing =>
                                              --   until end of stream,
                                              --   including entire last block)
           -> HalfsM m ByteString             -- ^ Stream contents
readStream dev startIR start mlen = do
  startCont <- drefInode dev startIR
  if 0 == blockCount startCont
   then return BS.empty
   else do 
     dbug ("==== readStream begin ===") $ do
     conts                         <- expandConts dev startCont
     (sContIdx, sBlkOff, sByteOff) <- getStreamIdx bs start conts
     --sIdx@(sContIdx, sBlkOff, sByteOff) <- decompStreamOffset bs start 
     dbug ("start = " ++ show start) $ do
     dbug ("(sContIdx, sBlkOff, sByteOff) = " ++ show (sContIdx, sBlkOff, sByteOff)) $ do
     --checkStreamBounds sIdx start conts

     case mlen of
       Just len | len == 0 -> return BS.empty
       _                   -> do
         case genericDrop sContIdx conts of
           [] -> fail "Inode.readStream INTERNAL: invalid start inode index"
           (inode:rest) -> do
             -- 'header' is just the partial first block and all remaining
             -- blocks in the first inode, accounting for the possible upper
             -- bound on the length of the data returned.
             assert (maybe True (> 0) mlen) $ return ()
             header <- do
               let remBlks = calcRemBlks inode (+ sByteOff)
                             -- +sByteOff to force rounding for partial blocks
                   range   = let lastIdx = blockCount inode - 1 in 
                             [ sBlkOff .. min lastIdx (sBlkOff + remBlks - 1) ]
               (blk:blks) <- mapM (readB inode) range
               return $ bsDrop sByteOff blk `BS.append` BS.concat blks

             -- 'fullBlocks' is the remaining content from all remaining
             -- conts, accounting for the possible upper bound on the length
             -- of the data returned.
             (fullBlocks, _readCnt) <- 
               foldM
                 (\(acc, bytesSoFar) inode' -> do
                    let remBlks = calcRemBlks inode' (flip (-) bytesSoFar) 
                        range   = if remBlks > 0 then [0..remBlks - 1] else []
                    blks <- mapM (readB inode') range
                    return ( acc `BS.append` BS.concat blks
                           , bytesSoFar + remBlks * bs
                           )
                 )
                 (BS.empty, fromIntegral $ BS.length header) rest

             dbug ("==== readStream end ===") $ return ()
             return $ 
               (maybe id bsTake mlen) $ header `BS.append` fullBlocks
  where
    bs        = bdBlockSize dev
    readB n b = lift $ readBlock dev n b
    -- 
    -- Calculate the remaining blocks (up to len, if applicable) to read from
    -- the given inode.  f is just a length modifier.
    calcRemBlks inode f =
      case mlen of 
        Nothing  -> blockCount inode
        Just len -> min (blockCount inode) $ f len `divCeil` bs

-- | Writes to the inode stream at the given starting inode and starting byte
-- offset, overwriting data and allocating new space on disk as needed.  If the
-- write is a truncating write, all resources after the end of the written data
-- are freed.
writeStream :: HalfsCapable b t r l m =>
               BlockDevice m   -- ^ The block device
            -> BlockMap b r l  -- ^ The block map
            -> InodeRef        -- ^ Starting inode ref
            -> Word64          -- ^ Starting stream (byte) offset
            -> Bool            -- ^ Truncating write?
            -> ByteString      -- ^ Data to write
            -> HalfsM m ()
writeStream _ _ _ _ _ bytes | 0 == BS.length bytes = return ()
writeStream dev bm startIR start trunc bytes       = do
  -- TODO: locking

  -- NB: This implementation currently 'flattens' Contig/Discontig block groups
  -- from the BlockMap allocator (see allocFill and truncUnalloc), which will
  -- force us to treat them as Discontig when we unallocate.  We may want to
  -- have the inodes hold onto these block groups directly and split/merge them
  -- as needed to reduce the number of unallocation actions required, but we'll
  -- leave this as a TODO for now.

  startCont <- drefInode dev startIR

  -- The start cont is extracted from the start inode, so it's by definition no
  -- larger (and smaller if there's any metadata) than subsequent conts.
  (bpsc, bpc, _, apc) <- getSizes bs
--   apsc <- computeNumInodeAddrsM bs  -- (block) addrs in start cont (inode)
--   bpsc <- return $ bs * apsc        -- bytes storable in start cont (inode)
--   apc  <- computeNumContAddrsM bs   -- (block) addrs per next conts
--   bpc  <- return $ bs * apc         -- bytes per next conts
--   assert (apsc <= apc && apsc == numAddrs startCont) $ return ()
--  api        <- computeNumInodeAddrsM bs -- (block) addrs per inode
--  bpi        <- return $ bs * api        -- bytes per inode

--  trace ("apsc = " ++ show apsc ++ ", bpsc = " ++ show bpsc ++ ", apc = " ++ show apc ++ ", bpc = " ++ show bpc) $ do

  -- NB: expandConts is probably not viable once cont chains get large, but the
  -- continuation scheme in general may not be viable.  Revisit after stuff is
  -- working.
  conts                         <- expandConts dev startCont
  (sContIdx, sBlkOff, sByteOff) <- getStreamIdx bs start conts
  --sIdx@(sContIdx, sBlkOff, sByteOff) <- decompStreamOffset bs start 
--  checkStreamBounds sIdx start conts

  dbug ("==== writeStream begin ===") $ do
--  dbug ("addrs per start cont      = " ++ show apsc)                           $ do
--  dbug ("addrs per cont            = " ++ show apc)                            $ do
  dbug ("inodeIdx, blkIdx, byteIdx = " ++ show (sContIdx, sBlkOff, sByteOff)) $ do
  dbug ("conts                     = " ++ show conts)                          $ do

  -- Determine how much space we need to allocate for the data, if any
  let allocdInBlk   = if sBlkOff < blockCount startCont then bs else 0
      allocdInStart = if sBlkOff + 1 < blockCount startCont
                      then bs * (blockCount startCont - sBlkOff - 1) else 0
      allocdInConts = sum $ map ((*bs) . blockCount) $
                      genericDrop (sContIdx + 1) conts
      alreadyAllocd = allocdInBlk + allocdInStart + allocdInConts
      bytesToAlloc  = if alreadyAllocd > len then 0 else len - alreadyAllocd
      blksToAlloc   = bytesToAlloc `divCeil` bs
      contsToAlloc  = (blksToAlloc - availBlks (last conts)) `divCeil` apc
      availBlks :: forall t. (Ord t, Serialize t) => BlockCarrier t -> Word64
      availBlks n   = numAddrs n - blockCount n

  dbug ("alreadyAllocd = " ++ show alreadyAllocd)          $ do
  dbug ("bytesToAlloc  = " ++ show bytesToAlloc)           $ do
  dbug ("blksToAlloc   = " ++ show blksToAlloc)            $ do
  dbug ("inodesToAlloc = " ++ show contsToAlloc)           $ do

  conts' <- allocFill dev bm availBlks blksToAlloc contsToAlloc conts

  let stCont = (conts' !! safeToInt sContIdx)
  sBlk <- lift $ readBlock dev stCont sBlkOff

  let (sData, bytes') = bsSplitAt (bs - sByteOff) bytes
      -- The first block-sized chunk to write is the region in the start block
      -- prior to the start byte offset (header), followed by the first bytes of
      -- the data.  The trailer is nonempty and must be included when BS.length
      -- bytes < bs.
      firstChunk =
        let header   = bsTake sByteOff sBlk
            trailLen = sByteOff + fromIntegral (BS.length sData)
            trailer  = if trunc
                       then bsReplicate (bs - trailLen) truncSentinel
                       else bsDrop trailLen sBlk
            r        = header `BS.append` sData `BS.append` trailer
        in assert (fromIntegral (BS.length r) == bs) r

      -- Destination block addresses starting at the the start block
      blkAddrs = genericDrop sBlkOff (blockAddrs stCont)
                 ++ concatMap blockAddrs (genericDrop (sContIdx + 1) conts')

  chunks <- (firstChunk:) `fmap`
            unfoldrM (lift . getBlockContents dev trunc)
                     (bytes', drop 1 blkAddrs)

  assert (all ((== safeToInt bs) . BS.length) chunks) $ do

  -- Write the remaining blocks
  mapM_ (\(a,d) -> lift $ bdWriteBlock dev a d) (blkAddrs `zip` chunks)

  -- If this is a truncating write, fix up the chain terminator & free all
  -- blocks & conts in the free region
  conts'' <- if trunc
              then truncUnalloc dev bm start len conts'
              else return conts'

  let inodesUpdated = 1 {- start cont -} + ((len - bpsc) `divCeil` bpc)
  dbug ("inodesUpdated = " ++ show inodesUpdated) $ return ()

  -- Update persisted inodes from the start inode to end of write region
  mapM_ (lift . writeBC dev) $
    genericTake inodesUpdated $ genericDrop sContIdx conts''

  -- TODO: Update metadata here? E.g., size, timestamps, etc?  Or should this
  -- happen up a level?  Also consider locked access at the 'header' inode.

  dbug ("==== writeStream end ===") $ do
  return ()
  where
    bs           = bdBlockSize dev
    len          = fromIntegral $ BS.length bytes


--------------------------------------------------------------------------------
-- Inode stream helper & utility functions 

-- | Allocate the given number of inodes and blocks, and fill blocks into the
-- given inode chain's block lists.  Newly allocated new inodes go at the end of
-- the given inode chain, and the result is the final inode chain to write data
-- into.
allocFill :: HalfsCapable b t r l m => 
             BlockDevice m              -- ^ The block device
          -> BlockMap b r l             -- ^ The block map to use for allocation
          -> (BlockCarrier t -> Word64) -- ^ Available blocks function
          -> Word64                     -- ^ Number of blocks to allocate
          -> Word64                     -- ^ Number of conts to allocate
          -> [BlockCarrier t]           -- ^ Chain to extend and fill
          -> HalfsM m [BlockCarrier t]
allocFill _   _  _     0           _            existing = return existing
allocFill dev bm avail blksToAlloc contsToAlloc existing = do
  newConts <- allocConts 
  blks     <- allocBlocks
  return []
  -- Fixup continuation fields and form the region that we'll fill with
  -- the newly allocated blocks (i.e., starting at the last inode but
  -- including the newly allocated inodes as well).
  let (_, region) = foldr (\bc (contAddr, acc) ->
                             ( CR $ address bc
                             , setContinuation bc contAddr : acc
                             )
                          )
                          (nilContRef, [])
                          (last existing : newConts)
  -- "Spill" the allocated blocks into the empty region
  let (blks', k)                   = foldl fillBlks (blks, id) region
      newChain                     = init existing ++ k []
      fillBlks (remBlks, k') bc =
        let cnt    = min (safeToInt $ avail bc) (length remBlks)
            bc'    = bc `setBlockCount`
                       (blockCount bc + fromIntegral cnt)
                       `setBlockAddrs`
                       (blockAddrs bc ++ take cnt remBlks)
--             inode' =
--               bc { inoBlockCount = inoBlockCount bc + fromIntegral cnt
--                  , inoBlocks     = inoBlocks bc ++ take cnt remBlks
--                  }
        in
          (drop cnt remBlks, k' . (bc':))
  
  assert (null blks') $ return ()
  assert (length newChain >= length existing) $ return ()
  return newChain
  where
    allocBlocks = do
      let n = blksToAlloc
      -- currently "flattens" BlockGroup; see comment in writeStream
      mbg <- lift $ BM.allocBlocks bm n
      case mbg of
        Nothing -> throwError HalfsAllocFailed
        Just bg -> return $ BM.blkRangeBG bg
    -- 
    allocConts =
      let n = contsToAlloc in
      if 0 == n
      then return []
      else do
        -- TODO: Catch allocation errors and unalloc partial allocs?
        mconts <- fmap sequence $ replicateM (safeToInt n) $ do
          mcr <- (fmap . fmap) CR (BM.alloc1 bm)
          case mcr of
            Nothing -> return Nothing
            Just cr -> Just `fmap` lift (buildEmptyCont dev cr)
        maybe (throwError HalfsAllocFailed) (return) mconts

-- | Truncates the stream at the given a stream index and length offset, and
-- unallocates all resources in the corresponding free region
truncUnalloc :: HalfsCapable b t r l m =>
                BlockDevice m             -- ^ the block device
             -> BlockMap b r l            -- ^ the block map
             -> Word64                    -- ^ starting stream byte index
             -> Word64                    -- ^ length from start at which to
                                          -- truncate
             -> [BlockCarrier t]          -- ^ current chain
             -> HalfsM m [BlockCarrier t] -- ^ truncated chain
truncUnalloc dev bm start len conts = do
  eIdx@(eContIdx, eBlkOff, _) <- decompStreamOffset (bdBlockSize dev) (start + len - 1)
  let 
    (retain, toFree) = genericSplitAt (eContIdx + 1) conts
    -- 
    trm         = last retain 
    retain'     = init retain ++ [trm']
    allFreeBlks = genericDrop (eBlkOff + 1) (blockAddrs trm)
                  -- ^ The remaining blocks in the terminator
                  ++ concatMap blockAddrs toFree
                  -- ^ The remaining blocks in rest of chain
                  ++ map address toFree
                  -- ^ Block addrs for the cont blocks themselves

    -- trm' is the new terminator cont, adjusted to discard the newly freed
    -- blocks and clear the continuation link
    trm' = trm
           `setBlockAddrs`
           (genericTake (eBlkOff + 1) (blockAddrs trm))
           `setBlockCount`
           (eBlkOff +1)
           `setContinuation`
           nilContRef
  
  dbug ("eIdx        = " ++ show eIdx)        $ return ()
  dbug ("retain'     = " ++ show retain')     $ return ()
  dbug ("freeNodes   = " ++ show toFree)      $ return ()
  dbug ("allFreeBlks = " ++ show allFreeBlks) $ return ()

  -- Freeing all of the blocks this way (as unit extents) is ugly and
  -- inefficient, but we need to be tracking BlockGroups (or reconstitute them
  -- here by looking for contiguous addresses in allFreeBlks) before we can do
  -- better.
    
  lift $ BM.unallocBlocks bm $ BM.Discontig $ map (`BM.Extent` 1) allFreeBlks
    
  -- We do not do any writes to any of the conts that were detached from the
  -- chain & freed; this may have implications for fsck!
  return retain'
--       term { continuation = Nothing
--            , blockCount   = eBlkOff + 1
--            , blockAddrs   = genericTake (eBlkOff + 1) (blockAddrs term)
--            }
--       term { inoContinuation = Nothing
--            , inoBlockCount   = eBlkOff + 1
--            , inoBlocks       = genericTake (eBlkOff + 1) $ inoBlocks term
--            }
    

-- | Splits the input bytestring into block-sized chunks; may read from the
-- block device in order to preserve contents of blocks if needed.
getBlockContents ::
  (Monad m, Functor m) => 
    BlockDevice m
  -- ^ The block device
  -> Bool
  -- ^ Truncating write? (Impacts partial block retention)
  -> (ByteString, [Word64])
  -- ^ Input bytestring, block addresses for each chunk (for retention)
  -> m (Maybe (ByteString, (ByteString, [Word64])))
  -- ^ Remaining bytestring & chunk addrs
getBlockContents _ _ (s, _) | BS.null s    = return Nothing
getBlockContents _ _ (_, [])               = return Nothing
getBlockContents dev trunc (s, blkAddr:blkAddrs) = do
  let (newBlkData, remBytes) = bsSplitAt bs s
      bs                     = bdBlockSize dev 
  if BS.null remBytes
   then do
     -- Last block; retain the relevant portion of its data
     trailer <-
       if trunc
       then return $ bsReplicate bs truncSentinel
       else
         bsDrop (BS.length newBlkData) `fmap` bdReadBlock dev blkAddr
     let rslt = bsTake bs $ newBlkData `BS.append` trailer
     return $ Just (rslt, (remBytes, blkAddrs))
   else do
     -- Full block; nothing to see here
     return $ Just (newBlkData, (remBytes, blkAddrs))

-- | Reads the contents of the given conts's ith block
readBlock :: (Ord t, Serialize t, Monad m) =>
                  BlockDevice m -> BlockCarrier t -> Word64 -> m ByteString
readBlock dev n i = do 
  assert (i < blockCount n) $ return ()
  bdReadBlock dev (blockAddrs n !! safeToInt i)

-- | Writes to the given inode's ith block
_writeInodeBlock :: (Ord t, Serialize t, Monad m) =>
                    BlockDevice m -> Inode t -> Word64 -> ByteString -> m ()
_writeInodeBlock dev n i bytes = do 
  assert (BS.length bytes == safeToInt (bdBlockSize dev)) $ return ()
  bdWriteBlock dev (inoBlocks n !! safeToInt i) bytes

-- Writes the given bc to its block address
writeBC :: (Ord t, Serialize t, Monad m, Show t) =>
              BlockDevice m -> BlockCarrier t -> m ()
writeBC dev bc = bdWriteBlock dev (address bc) (encode bc) 

-- | Expands the given inode into an inode list containing itself followed by
-- all of its continuation inodes

-- NB/TODO: We need to optimize/fix this function. The worst case is, e.g.,
-- writing a small number of bytes at a low offset into a huge file (and hence a
-- long continuation chain): we read the entire chain when examination of the
-- stream from the start to end offsets would be sufficient.

expandConts :: HalfsCapable b t r l m =>
               BlockDevice m -> BlockCarrier t -> HalfsM m [BlockCarrier t]
expandConts dev bc@BC{ continuation = cr }
  | cr == nilContRef = return [bc]
  | otherwise        = (bc:) `fmap` (drefCont dev cr >>= expandConts dev)

-- expandConts :: HalfsCapable b t r l m =>
--                BlockDevice m -> Inode t -> HalfsM m [Inode t]
-- expandConts _   inode@Inode{ inoContinuation = Nothing      } = return [inode]
-- expandConts dev inode@Inode{ inoContinuation = Just nextRef } = 
--   (inode:) `fmap` (drefInode dev nextRef >>= expandConts dev)

drefCont :: HalfsCapable b t r l m =>
        BlockDevice m -> ContRef -> HalfsM m (BlockCarrier t)
drefCont dev (CR addr) =
  lift (bdReadBlock dev addr) >>= decodeBC (bdBlockSize dev)
--    >>= decodeCont (bdBlockSize dev) >>= return . contBC

drefInode :: HalfsCapable b t r l m => 
             BlockDevice m -> InodeRef -> HalfsM m (BlockCarrier t)
drefInode dev (IR addr) = do 
  lift (bdReadBlock dev addr) >>= decodeBC (bdBlockSize dev) 
--    >>= decodeInode (bdBlockSize dev) >>= return . inodeBC

{-
testDecomp :: (Serialize t, Timed t m, Monad m) =>
              Word64 -> HalfsT m StreamIdx
testDecomp start = do
  conts <- (:[]) `fmap` buildEmptyInode BlockDevice{ bdBlockSize = 512 } nilInodeRef nilInodeRef rootUser rootGroup
  decompStreamOffset 512 start 
-}

-- | Decompose the given absolute byte offset into an inode's data stream into
-- BlockCarrier index (i.e., 0-based index inot the carrier chain), block offset
-- within that BlockCarrier, and byte offset within that block.  Note that
-- Inodes are BlockCarriers with less capacity than Conts, and we only ever have
-- one Inode in a chain and it will always be the first carrier, so we track the
-- smaller capacity explicitly.
decompStreamOffset :: (Serialize t, Timed t m, Monad m) => 
                      Word64           -- ^ Block size, in bytes
                   -> Word64           -- ^ Offset into the data stream
                   -> HalfsM m StreamIdx
decompStreamOffset blkSz streamOff = do
  (stContBytes, contBytes, _, _) <- getSizes blkSz
  let (contIdx, contByteIdx) =
        if streamOff >= stContBytes
        then fmapFst (+1) $ (streamOff - stContBytes) `divMod` contBytes
        else (0, streamOff)
      (blkOff, byteOff)      = contByteIdx `divMod` blkSz
  return (contIdx, blkOff, byteOff)

getStreamIdx :: HalfsCapable b t r l m =>
                Word64 -- block size in bytse
             -> Word64 -- start byte index
             -> [BlockCarrier t]
             -> HalfsM m StreamIdx
getStreamIdx blkSz start conts  = do
  sIdx <- decompStreamOffset blkSz start
  when (bad sIdx) $ throwError $ HalfsInvalidStreamIndex start
  return sIdx
  where
    -- Sanity check
    bad (sContIdx, sBlkOff, _) =
      sContIdx >= fromIntegral (length conts)
      ||
      let blkCnt = blockCount (conts !! safeToInt sContIdx)
      in
        sBlkOff >= blkCnt && not (sBlkOff == 0 && blkCnt == 0)

{-
-- | Adds a byte offset to a (cont index, block index, byte index) triple
addOffset :: (Monad m, Timed t m, Serialize t) =>
             Word64                     -- block size in bytes
          -> Word64                     -- byte offset
          -> (Word64, Word64, Word64)   -- start index
          -> m (Word64, Word64, Word64) -- offset index
addOffset blkSz offset (contIdx, blkIdx, byteIdx) =
  getSizes blkSz >>= return . calc
  where
    calc (stContBytes, contBytes) =
      (contIdx + contOff + inds, blks', b)
    (contOff, contByteOff) = offset `divMod` (blksPerInode * blkSz)
    (blkOff, byteOff)        = contByteOff `divMod` blkSz
    (blks, b)                = (byteIdx + byteOff) `divMod` blkSz
    (inds, blks')            = (blkIdx + blkOff + blks) `divMod` blksPerInode
-}
    
-- | A wrapper around Data.Serialize.decode that populates transient fields.  We
-- do this to avoid occupying valuable on-disk inode space where possible.  Bare
-- applications of 'decode' should not occur when deserializing inodes.
decodeInode :: HalfsCapable b t r l m =>
               Word64
            -> ByteString
            -> HalfsM m (Inode t)
decodeInode _blkSz _bs = do
  return undefined
--   numAddrs' <- computeNumInodeAddrsM blkSz
--   case decode bs of
--     Left s  -> throwError $ HalfsDecodeFail_Inode s
--     Right n -> return n{ inoNumAddrs = numAddrs' }

decodeCont :: HalfsCapable b t r l m =>
              Word64
           -> ByteString
           -> HalfsM m Cont
decodeCont _blkSz _bs = do
  return undefined
--   numAddrs' <- computeNumContAddrsM blkSz
--   case decode bs of
--     Left s  -> throwError $ HalfsDecodeFail_Cont s
--     Right c -> return c{ inocNumAddrs = numAddrs' }

decodeBC :: HalfsCapable b t r l m =>
            Word64
         -> ByteString
         -> HalfsM m (BlockCarrier t)
decodeBC blkSz bs = do
  case decode bs of
    Left    s -> throwError $ HalfsDecodeFail_BlockCarrier s
    Right eic -> case eic of
      Left n  -> do numAddrs' <- computeNumInodeAddrsM blkSz
                    return $ inodeBC $ n{ inoNumAddrs = numAddrs' }
      Right c -> do numAddrs' <- computeNumContAddrsM  blkSz
                    return $ contBC $ c{ inocNumAddrs = numAddrs' }

-- "Safe" (i.e., emits runtime assertions on overflow) versions of
-- BS.{take,drop,replicate}.  We want the efficiency of these functions without
-- the danger of an unguarded fromIntegral on the Word64 types we use throughout
-- this module, as this could overflow for absurdly large device geometries.  We
-- may need to revisit some implementation decisions should this occur (e.g.,
-- because many Prelude and Data.ByteString functions yield and take values of
-- type Int).

safeToInt :: Integral a => a -> Int
safeToInt n =
  assert (toInteger n <= toInteger (maxBound :: Int)) $ fromIntegral n

makeSafeIntF :: Integral a =>  (Int -> b) -> a -> b
makeSafeIntF f n = f $ safeToInt n

-- | "Safe" version of Data.ByteString.take
bsTake :: Integral a => a -> ByteString -> ByteString
bsTake = makeSafeIntF BS.take

-- | "Safe" version of Data.ByteString.drop
bsDrop :: Integral a => a -> ByteString -> ByteString
bsDrop = makeSafeIntF BS.drop

-- | "Safe" version of Data.ByteString.replicate
bsReplicate :: Integral a => a -> Word8 -> ByteString
bsReplicate = makeSafeIntF BS.replicate

bsSplitAt :: Integral a => a -> ByteString -> (ByteString, ByteString)
bsSplitAt = makeSafeIntF BS.splitAt


--------------------------------------------------------------------------------
-- Magic numbers

magicStr :: String
magicStr = "This is a halfs Inode structure!"

magicBytes :: [Word8]
magicBytes = assert (length magicStr == 32) $
             map (fromIntegral . ord) magicStr

magic1, magic2, magic3, magic4 :: ByteString
magic1 = BS.pack $ take 8 $ drop  0 magicBytes
magic2 = BS.pack $ take 8 $ drop  8 magicBytes
magic3 = BS.pack $ take 8 $ drop 16 magicBytes
magic4 = BS.pack $ take 8 $ drop 24 magicBytes

magicContStr :: String
magicContStr = "!!erutcurts tnoC sflah a si sihT"

magicContBytes :: [Word8]
magicContBytes = assert (length magicContStr == 32) $
                 map (fromIntegral . ord) magicStr

cmagic1, cmagic2, cmagic3, cmagic4 :: ByteString
cmagic1 = BS.pack $ take 8 $ drop  0 magicContBytes
cmagic2 = BS.pack $ take 8 $ drop  8 magicContBytes
cmagic3 = BS.pack $ take 8 $ drop 16 magicContBytes
cmagic4 = BS.pack $ take 8 $ drop 24 magicContBytes
